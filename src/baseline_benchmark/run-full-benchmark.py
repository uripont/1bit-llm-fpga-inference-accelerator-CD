#!/usr/bin/env python3
import argparse
import csv
import json
import os
import re
import subprocess
from collections import defaultdict
from pathlib import Path


FIELDS = ("calls", "time_us", "dst_elems", "q1_groups", "weight_apps")
LOG_RE = re.compile(r"pl_(\d+)_pp_(\d+)_tg_(\d+)\.log$")


def parse_int_list(value):
    return [int(item) for item in value.replace(",", " ").split() if item]


def parse_log(path):
    text = Path(path).read_text(errors="replace")
    bench_line = next((line for line in text.splitlines() if line.startswith("{")), None)
    if bench_line is None:
        return None, None
    bench = json.loads(bench_line.replace("nan", "NaN"))

    records = defaultdict(lambda: {field: 0 for field in FIELDS})
    section = None
    header = None

    for line in text.splitlines():
        if line.startswith("GGML_CPU_OP_PROFILE"):
            section = "cpu"
            header = None
            continue
        if line.startswith("GGML_BLAS_OP_PROFILE"):
            section = "blas"
            header = None
            continue
        if section and line.startswith("op,"):
            header = line.split(",")
            continue
        if section and header and line and not line.startswith("llama_"):
            parts = line.split(",")
            if len(parts) != len(header):
                continue
            row = dict(zip(header, parts))
            key = (section, row["op"], row["src0_type"])
            for field in FIELDS:
                records[key][field] += int(row[field])

    return bench, records


def sum_field(records, field, op=None, src0_type=None):
    return sum(
        values[field]
        for (_, record_op, record_type), values in records.items()
        if (op is None or record_op == op)
        and (src0_type is None or record_type == src0_type)
    )


def subtract_records(total, base):
    result = defaultdict(lambda: {field: 0 for field in FIELDS})
    for key in set(total) | set(base):
        for field in FIELDS:
            # Profile timers come from separate benchmark runs, so small timing
            # differences can make total-prefill negative for a few ops.
            result[key][field] = max(0, total[key][field] - base[key][field])
    return result


def op_time(records):
    grouped = defaultdict(int)
    for (_, op, src0_type), values in records.items():
        grouped[(op, src0_type)] += values["time_us"]
    return grouped


def pct(value, total):
    return 100.0 * value / total if total > 0 else 0.0


def speedup_if_fraction_accelerated(fraction, accel):
    if fraction <= 0:
        return 1.0
    return 1.0 / ((1.0 - fraction) + fraction / accel)


def verdict(q1_pct, attn_pct, speedup_10x, speedup_100x):
    if q1_pct >= 70.0 and speedup_10x >= 2.5:
        return "strong Q1-prefill target"
    if q1_pct >= 45.0 and speedup_100x >= 1.8:
        return "mixed; Q1 helps but attention also matters"
    if attn_pct >= q1_pct:
        return "attention/memory co-bottleneck"
    return "limited Q1-only upside"


def run_benchmark(args):
    args.output_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["GGML_CPU_OP_PROFILE"] = "1"
    env["GGML_CPU_OP_PROFILE_SKIP_GRAPHS"] = str(args.profile_skip_graphs)

    for pl in args.parallelism:
        for pp in args.prompts:
            for tg in (0, args.decode_tokens):
                out = args.output_dir / f"pl_{pl}_pp_{pp}_tg_{tg}.log"
                cmd = [
                    str(args.bin),
                    "-m", str(args.model),
                    "-c", str(args.ctx_size),
                    "-b", str(args.batch),
                    "-ub", str(args.ubatch),
                    "-t", str(args.threads),
                    "-npp", str(pp),
                    "-ntg", str(tg),
                    "-npl", str(pl),
                    "--output-format", "jsonl",
                ]
                print(f"running pl={pl} pp={pp} tg={tg} -> {out}")
                with out.open("w") as handle:
                    subprocess.run(cmd, check=True, env=env, stdout=handle, stderr=subprocess.STDOUT)


def load_logs(input_dir):
    by_key = {}
    for path in sorted(input_dir.glob("pl_*_pp_*_tg_*.log")):
        match = LOG_RE.search(path.name)
        if not match:
            continue
        parsed = parse_log(path)
        if parsed[0] is None:
            continue
        by_key[tuple(map(int, match.groups()))] = parsed
    return by_key


def write_prefill_summary(by_key, output_path):
    rows = []
    for (pl, pp, tg), (bench, records) in sorted(by_key.items()):
        if tg != 0 or pp == 0:
            continue
        total_us = sum_field(records, "time_us")
        q1_us = sum_field(records, "time_us", "MUL_MAT", "q1_0")
        attn_us = sum_field(records, "time_us", "FLASH_ATTN_EXT")
        other_us = total_us - q1_us - attn_us
        q1_frac = q1_us / total_us if total_us > 0 else 0.0
        sp10 = speedup_if_fraction_accelerated(q1_frac, 10.0)
        sp100 = speedup_if_fraction_accelerated(q1_frac, 100.0)
        q1_pct = pct(q1_us, total_us)
        attn_pct = pct(attn_us, total_us)
        rows.append({
            "pl": pl,
            "pp": pp,
            "prefill_s": f"{bench['t_pp']:.6f}",
            "prefill_tok_s": f"{bench['speed_pp']:.3f}",
            "profile_s": f"{total_us / 1e6:.6f}",
            "q1_matmul_s": f"{q1_us / 1e6:.6f}",
            "q1_matmul_pct": f"{q1_pct:.2f}",
            "attention_s": f"{attn_us / 1e6:.6f}",
            "attention_pct": f"{attn_pct:.2f}",
            "other_s": f"{other_us / 1e6:.6f}",
            "other_pct": f"{pct(other_us, total_us):.2f}",
            "q1_groups": sum_field(records, "q1_groups"),
            "weight_apps": sum_field(records, "weight_apps"),
            "speedup_if_q1_10x": f"{sp10:.2f}",
            "speedup_if_q1_100x": f"{sp100:.2f}",
            "verdict": verdict(q1_pct, attn_pct, sp10, sp100),
        })
    write_csv(output_path, rows)


def write_decode_summary(by_key, output_path):
    rows = []
    best_tg_by_prompt = {}
    for pl, pp, tg in by_key:
        if tg > 0:
            best_tg_by_prompt[(pl, pp)] = max(tg, best_tg_by_prompt.get((pl, pp), 0))

    for (pl, pp, tg), (bench_total, records_total) in sorted(by_key.items()):
        if tg == 0:
            continue
        if tg != best_tg_by_prompt.get((pl, pp)):
            continue
        base = by_key.get((pl, pp, 0))
        if base is None:
            continue
        records = subtract_records(records_total, base[1])
        total_us = sum_field(records, "time_us")
        q1_us = sum_field(records, "time_us", "MUL_MAT", "q1_0")
        attn_us = sum_field(records, "time_us", "FLASH_ATTN_EXT")
        other_us = total_us - q1_us - attn_us
        others = []
        for (op, src0_type), time_us in op_time(records).items():
            if op == "MUL_MAT" and src0_type == "q1_0":
                continue
            if op == "FLASH_ATTN_EXT":
                continue
            if time_us > 0:
                others.append((time_us, op, src0_type))
        others.sort(reverse=True)
        top_other = ";".join(f"{op}:{src0_type}:{time_us / 1e6:.4f}s" for time_us, op, src0_type in others[:4])
        rows.append({
            "pl": pl,
            "pp": pp,
            "tg": tg,
            "decode_s": f"{bench_total['t_tg']:.6f}",
            "decode_tok_s": f"{bench_total['speed_tg']:.3f}",
            "decode_profile_s": f"{total_us / 1e6:.6f}",
            "q1_matmul_pct": f"{pct(q1_us, total_us):.2f}",
            "attention_pct": f"{pct(attn_us, total_us):.2f}",
            "other_pct": f"{pct(other_us, total_us):.2f}",
            "q1_matmul_s": f"{q1_us / 1e6:.6f}",
            "attention_s": f"{attn_us / 1e6:.6f}",
            "other_s": f"{other_us / 1e6:.6f}",
            "top_other": top_other,
        })
    write_csv(output_path, rows)


def write_csv(output_path, rows):
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        print(f"no rows for {output_path}")
        return
    with output_path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Run and summarize Bonsai/Q1_0 CPU baseline profiling.")
    parser.add_argument("--model", type=Path, default=Path("models/bonsai-1.7b-gguf/Bonsai-1.7B-Q1_0.gguf"))
    parser.add_argument("--bin", type=Path, default=Path("external/llama.cpp/build-cpu/bin/llama-batched-bench"))
    parser.add_argument("--output-dir", type=Path, default=Path("results/baseline_benchmark/full"))
    parser.add_argument("--input-dir", type=Path, default=None)
    parser.add_argument("--summarize-only", action="store_true")
    parser.add_argument("--ctx-size", type=int, default=33024)
    parser.add_argument("--batch", type=int, default=512)
    parser.add_argument("--ubatch", type=int, default=512)
    parser.add_argument("--threads", type=int, default=6)
    parser.add_argument("--prompts", default="0 128 512 2048 4096 8192 16384 32768")
    parser.add_argument("--decode-tokens", type=int, default=128)
    parser.add_argument("--parallelism", default="1")
    parser.add_argument("--profile-skip-graphs", type=int, default=1)
    args = parser.parse_args()

    args.prompts = parse_int_list(args.prompts)
    args.parallelism = parse_int_list(args.parallelism)

    if not args.summarize_only:
        if not args.bin.exists():
            raise SystemExit(f"missing llama-batched-bench: {args.bin}")
        if not args.model.exists():
            raise SystemExit(f"missing model: {args.model}")
        run_benchmark(args)

    input_dir = args.input_dir or args.output_dir
    by_key = load_logs(input_dir)
    write_prefill_summary(by_key, input_dir / "prefill-summary.csv")
    write_decode_summary(by_key, input_dir / "decode-summary.csv")


if __name__ == "__main__":
    main()
