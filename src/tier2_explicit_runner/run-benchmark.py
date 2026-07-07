#!/usr/bin/env python3
import argparse
import csv
import re
import subprocess
import time
from pathlib import Path


METRIC_RE = re.compile(r"([A-Za-z0-9_]+)=([^ ]+)")


def parse_int_list(value):
    return [int(item) for item in value.replace(",", " ").split() if item]


def run(cmd, cwd, output_path=None):
    started = time.perf_counter()
    result = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, check=False)
    elapsed = time.perf_counter() - started
    text = result.stdout + result.stderr
    if output_path is not None:
        output_path.write_text(text)
    if result.returncode != 0:
        raise RuntimeError(
            "command failed:\n"
            + " ".join(map(str, cmd))
            + "\nstdout/stderr:\n"
            + text
        )
    return text, elapsed


def build_runner(repo, source, runner):
    run(
        [
            "c++",
            "-std=c++17",
            "-O3",
            "-Wall",
            "-Wextra",
            "-Wpedantic",
            str(source),
            "-o",
            str(runner),
        ],
        repo,
    )


def parse_kv_line(line):
    out = {}
    for key, value in METRIC_RE.findall(line):
        try:
            out[key] = int(value)
        except ValueError:
            try:
                out[key] = float(value)
            except ValueError:
                out[key] = value
    return out


def parse_log(path, elapsed_s):
    rows = {}
    generated = []
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("backend_metrics "):
            rows["backend"] = parse_kv_line(line)
        elif line.startswith("decode_summary "):
            rows["decode"] = parse_kv_line(line)
        elif line.startswith("generated_token "):
            generated.append(parse_kv_line(line))
    if "backend" not in rows:
        raise RuntimeError(f"missing backend_metrics in {path}")
    if "decode" not in rows:
        raise RuntimeError(f"missing decode_summary in {path}")
    rows["elapsed_s"] = elapsed_s
    rows["generated"] = generated
    return rows


def write_csv(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        return
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {path}")


def load_existing_elapsed(path):
    if not path.exists():
        return {}
    with path.open(newline="") as handle:
        return {row["label"]: float(row["elapsed_s"]) for row in csv.DictReader(handle) if row.get("elapsed_s")}


def summarize_run(label, token_count, tokens, parsed):
    backend = parsed["backend"]
    decode = parsed["decode"]
    generated = parsed["generated"]
    transformer_dot = backend["transformer_q1_dot_elements"]
    lm_head_dot = backend["lm_head_q1_dot_elements"]
    total_q1_dot = transformer_dot + lm_head_dot
    total_q1_groups = backend["transformer_q1_groups_128"] + backend["lm_head_q1_groups_128"]
    total_attention_mac = backend["attention_score_mac"] + backend["attention_value_mac"]
    generated_tokens = ",".join(str(row["token"]) for row in generated)

    return {
        "label": label,
        "input_tokens": token_count,
        "tokens": ",".join(str(token) for token in tokens),
        "generated_tokens": generated_tokens,
        "elapsed_s": f"{parsed['elapsed_s']:.3f}",
        "decode_layers": decode["layers"],
        "rms_norms": decode["rms_norms"],
        "residual_adds": decode["residual_adds"],
        "silu_gate_products": decode["silu_gate_products"],
        "q1_backend_calls": decode["q1_backend_calls"],
        "attention_backend_calls": decode["attention_backend_calls"],
        "lm_head_calls": decode["lm_head_calls"],
        "transformer_q1_calls": backend["transformer_q1_matvec_calls"],
        "lm_head_q1_calls": backend["lm_head_q1_matvec_calls"],
        "total_q1_calls": backend["transformer_q1_matvec_calls"] + backend["lm_head_q1_matvec_calls"],
        "transformer_q1_rows": backend["transformer_q1_rows"],
        "lm_head_q1_rows": backend["lm_head_q1_rows"],
        "total_q1_rows": backend["transformer_q1_rows"] + backend["lm_head_q1_rows"],
        "transformer_q1_dot_elements": transformer_dot,
        "lm_head_q1_dot_elements": lm_head_dot,
        "total_q1_dot_elements": total_q1_dot,
        "total_q1_groups_128": total_q1_groups,
        "attention_calls": backend["attention_calls"],
        "attention_score_mac": backend["attention_score_mac"],
        "attention_value_mac": backend["attention_value_mac"],
        "total_attention_mac": total_attention_mac,
        "q1_dot_elements_per_token": total_q1_dot // token_count,
        "q1_groups_128_per_token": total_q1_groups // token_count,
        "attention_mac_per_token_avg": total_attention_mac // token_count,
    }


def main():
    parser = argparse.ArgumentParser(description="Run and summarize the Tier 2 explicit Bonsai runner.")
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--model", type=Path, default=Path("models/bonsai-1.7b-gguf/Bonsai-1.7B-Q1_0.gguf"))
    parser.add_argument("--source", type=Path, default=Path("src/tier2_explicit_runner/bonsai-explicit-runner.cpp"))
    parser.add_argument("--runner", type=Path, default=Path("/tmp/bonsai-explicit-runner-benchmark"))
    parser.add_argument("--output-dir", type=Path, default=Path("results/tier2_explicit_runner/full"))
    parser.add_argument("--tokens", default="0 2928 9707 785")
    parser.add_argument("--lengths", default="1 2 4")
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--summarize-only", action="store_true")
    args = parser.parse_args()

    repo = args.repo.resolve()
    model = args.model if args.model.is_absolute() else repo / args.model
    source = args.source if args.source.is_absolute() else repo / args.source
    output_dir = args.output_dir if args.output_dir.is_absolute() else repo / args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    tokens = parse_int_list(args.tokens)
    lengths = parse_int_list(args.lengths)
    if not tokens:
        raise SystemExit("at least one token id is required")
    if not lengths:
        raise SystemExit("at least one length is required")
    if max(lengths) > len(tokens):
        raise SystemExit("--lengths cannot exceed the number of --tokens")

    rows = []
    elapsed_by_log = {}
    existing_elapsed = load_existing_elapsed(output_dir / "decode-summary.csv") if args.summarize_only else {}
    if not args.summarize_only:
        if not model.exists():
            raise SystemExit(f"missing model: {model}")
        build_runner(repo, source, args.runner)

        check_log = output_dir / "check-q1.log"
        print(f"running check_q1 -> {check_log}")
        run([str(args.runner), "--model", str(model), "--check-q1"], repo, check_log)

        for length in lengths:
            selected = tokens[:length]
            label = f"tokens_{length}"
            log_path = output_dir / f"{label}.log"
            print(f"running {label} -> {log_path}")
            _, elapsed = run(
                [
                    str(args.runner),
                    "--model",
                    str(model),
                    "--trace-one-token",
                    "--top-k",
                    str(args.top_k),
                    "--tokens",
                    ",".join(str(token) for token in selected),
                ],
                repo,
                log_path,
            )
            elapsed_by_log[log_path.name] = elapsed

    for length in lengths:
        selected = tokens[:length]
        label = f"tokens_{length}"
        log_path = output_dir / f"{label}.log"
        if not log_path.exists():
            raise SystemExit(f"missing log for summary: {log_path}")
        elapsed = elapsed_by_log.get(log_path.name, existing_elapsed.get(label, 0.0))
        rows.append(summarize_run(label, length, selected, parse_log(log_path, elapsed)))

    write_csv(output_dir / "decode-summary.csv", rows)


if __name__ == "__main__":
    main()
