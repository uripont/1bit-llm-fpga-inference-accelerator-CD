#!/usr/bin/env python3
"""Evaluate a Proposal B frontend against Tier 3 attention/KV baselines."""

from __future__ import annotations

import argparse
import csv
import selectors
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ACCEL = ROOT / "src" / "neorv32_bonsai_accelerator"
FIRMWARE = ACCEL / "sw" / "attention_kv_evaluation"
RESULTS_ROOT = ROOT / "results" / "proposal_b_evaluation" / "attention_kv"
CONTAINER_ROOT = Path("/workspaces/1bit-llm-fpga-inference-accelerator-CD")
CONTAINER_FIRMWARE = (
    CONTAINER_ROOT / "src" / "neorv32_bonsai_accelerator" /
    "sw" / "attention_kv_evaluation"
)


@dataclass(frozen=True)
class Profile:
  name: str
  run: str
  heads: int
  kv_heads: int
  head_dim: int
  ctx: int
  imem_size: int
  dmem_size: int
  rom_size: str
  ram_size: str
  stop_time: str
  tier3_csv: Path


PROFILES = {
    "board": Profile(
        name="board",
        run="kv_tile_ctx2_softmax_exact",
        heads=1,
        kv_heads=1,
        head_dim=32,
        ctx=2,
        imem_size=16 * 1024,
        dmem_size=8 * 1024,
        rom_size="16k",
        ram_size="8k",
        stop_time="8ms",
        tier3_csv=ROOT / "results" / "tier3_neorv32_cycle_kernels" /
        "attention_kv" / "board" / "summary.csv",
    ),
    "bonsai": Profile(
        name="bonsai",
        run="kv_bonsai_gqa_ctx2_softmax_exact",
        heads=2,
        kv_heads=1,
        head_dim=16,
        ctx=2,
        imem_size=256 * 1024,
        dmem_size=128 * 1024,
        rom_size="256k",
        ram_size="128k",
        stop_time="8ms",
        tier3_csv=ROOT / "results" / "tier3_neorv32_cycle_kernels" /
        "attention_kv" / "bonsai" / "summary.csv",
    ),
}


SUMMARY_FIELDS = [
    "run", "profile", "heads", "kv_heads", "head_dim", "ctx",
    "input_source", "normalization_mode", "transfer_mode",
    "cpu_push_strategy", "memory_strategy", "score_mac", "value_mac", "softmax_elements",
    "logical_kv_read_bytes", "logical_kv_write_bytes",
    "logical_kv_total_bytes", "software_append_cycles",
    "software_score_cycles", "software_norm_cycles", "software_value_cycles",
    "software_service_cycles", "command_cycles", "engine_cycles",
    "active_cycles", "input_wait_cycles", "output_wait_cycles",
    "control_cycles", "frontend_input_wait", "frontend_output_wait",
    "physical_input_bytes", "physical_output_bytes", "input_transactions",
    "output_transactions", "work_mac", "command_speedup", "engine_speedup",
    "active_cycle_speedup", "command_cycle_reduction_percent",
    "cpu_push_command_cycles", "mem_stream_vs_cpu_push_speedup",
    "cpu_push_frontend_input_wait", "frontend_input_wait_reduction_percent",
    "cpu_push_frontend_output_wait", "frontend_output_wait_reduction_percent",
    "engine_utilization_percent", "engine_input_wait_percent",
    "command_cycles_per_mac", "active_cycles_per_mac", "checksum",
    "expected_checksum", "evaluation_status", "simulation_wall_seconds",
    "stop_time",
]


def run_streamed(cmd: list[str], cwd: Path, log: Path, timeout: int,
                 label: str, append: bool = False) -> tuple[str, float]:
  print(f"[start] {label}", flush=True)
  print("+", " ".join(cmd), flush=True)
  log.parent.mkdir(parents=True, exist_ok=True)
  started = time.monotonic()
  last_progress = started
  parts: list[str] = []

  with log.open("a" if append else "w", encoding="utf-8") as log_file:
    proc = subprocess.Popen(
        cmd, cwd=cwd, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    assert proc.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    while True:
      for key, _ in selector.select(timeout=1.0):
        line = key.fileobj.readline()
        if line:
          parts.append(line)
          print(line, end="", flush=True)
          log_file.write(line)
          log_file.flush()
      if proc.poll() is not None:
        rest = proc.stdout.read()
        if rest:
          parts.append(rest)
          print(rest, end="", flush=True)
          log_file.write(rest)
        break
      now = time.monotonic()
      if now - last_progress >= 30.0:
        progress = f"[progress] {label}: {now - started:.0f}s elapsed\n"
        print(progress, end="", flush=True)
        log_file.write(progress)
        log_file.flush()
        last_progress = now
      if now - started > timeout:
        proc.kill()
        raise TimeoutError(f"{label} timed out after {timeout}s")

  elapsed = time.monotonic() - started
  output = "".join(parts)
  if proc.returncode != 0:
    raise RuntimeError(f"{label} failed; inspect {log}\n{output[-2000:]}")
  print(f"[done] {label}: {elapsed:.1f}s", flush=True)
  return output, elapsed


def parse_kv(text: str) -> dict[str, str]:
  values: dict[str, str] = {}
  for line in text.splitlines():
    if "=" not in line:
      continue
    key, value = line.strip().split("=", 1)
    if key and key[0].isalpha() and all(c.isalnum() or c == "_" for c in key):
      values[key] = value
  return values


def read_tier3(profile: Profile) -> dict[str, str]:
  with profile.tier3_csv.open(newline="", encoding="utf-8") as source:
    rows = list(csv.DictReader(source))
  matches = [row for row in rows if row["run"] == profile.run]
  if len(matches) != 1:
    raise RuntimeError(f"expected one {profile.run} row in {profile.tier3_csv}")
  return matches[0]


def quotient(numerator: int, denominator: int) -> str:
  return f"{numerator / denominator:.6f}" if denominator else ""


def percent(numerator: int, denominator: int) -> str:
  return f"{100.0 * numerator / denominator:.3f}" if denominator else ""


def validate_compatibility(profile: Profile, software: dict[str, str],
                           hardware: dict[str, str]) -> None:
  expected = {
      "heads": str(profile.heads),
      "kv_heads": str(profile.kv_heads),
      "head_dim": str(profile.head_dim),
      "ctx": str(profile.ctx),
      "input_source": software["input_source"],
      "score_mac": software["score_mac"],
      "value_mac": software["value_mac"],
      "softmax_elements": software["softmax_elements"],
      "checksum": software["checksum"],
      "expected_checksum": software["checksum"],
      "evaluation_status": "PASS",
  }
  mismatches = [
      f"{key}: expected {value}, got {hardware.get(key, '<missing>')}"
      for key, value in expected.items() if hardware.get(key) != value
  ]
  if mismatches:
    raise RuntimeError("compatibility check failed:\n  " + "\n  ".join(mismatches))


def make_result(profile: Profile, software: dict[str, str],
                hardware: dict[str, str], wall_seconds: float,
                transfer_mode: str, stop_time: str) -> dict[str, str]:
  validate_compatibility(profile, software, hardware)
  sw = int(software["service_cycles"])
  command = int(hardware["command_cycles"])
  engine = int(hardware["engine_cycles"])
  active = int(hardware["active_cycles"])
  input_wait = int(hardware["input_wait_cycles"])
  work = int(hardware["work_mac"])

  result = {key: hardware.get(key, "") for key in SUMMARY_FIELDS}
  result.update({
      "run": profile.run,
      "profile": profile.name,
      "logical_kv_read_bytes": software["kv_read_bytes"],
      "logical_kv_write_bytes": software["kv_write_bytes"],
      "logical_kv_total_bytes": software["kv_total_bytes"],
      "software_append_cycles": software["append_cycles"],
      "software_score_cycles": software["score_cycles"],
      "software_norm_cycles": software["norm_cycles"],
      "software_value_cycles": software["value_cycles"],
      "software_service_cycles": str(sw),
      "physical_input_bytes": hardware["input_bytes"],
      "physical_output_bytes": hardware["output_bytes"],
      "command_speedup": quotient(sw, command),
      "engine_speedup": quotient(sw, engine),
      "active_cycle_speedup": quotient(sw, active),
      "command_cycle_reduction_percent": f"{100.0 * (sw - command) / sw:.3f}",
      "engine_utilization_percent": percent(active, engine),
      "engine_input_wait_percent": percent(input_wait, engine),
      "command_cycles_per_mac": quotient(command, work),
      "active_cycles_per_mac": quotient(active, work),
      "simulation_wall_seconds": f"{wall_seconds:.3f}",
      "stop_time": stop_time,
  })
  if transfer_mode == "mem_stream":
    cpu_summary = RESULTS_ROOT / "cpu_push" / "summary.csv"
    with cpu_summary.open(newline="", encoding="utf-8") as source:
      cpu_rows = list(csv.DictReader(source))
    cpu = next(row for row in cpu_rows if row["profile"] == profile.name)
    cpu_command = int(cpu["command_cycles"])
    cpu_frontend_input_wait = int(cpu["frontend_input_wait"])
    cpu_frontend_output_wait = int(cpu["frontend_output_wait"])
    mem_frontend_input_wait = int(hardware["frontend_input_wait"])
    mem_frontend_output_wait = int(hardware["frontend_output_wait"])
    result.update({
        "cpu_push_command_cycles": str(cpu_command),
        "mem_stream_vs_cpu_push_speedup": quotient(cpu_command, command),
        "cpu_push_frontend_input_wait": str(cpu_frontend_input_wait),
        "frontend_input_wait_reduction_percent":
            f"{100.0 * (cpu_frontend_input_wait - mem_frontend_input_wait) / cpu_frontend_input_wait:.3f}"
            if cpu_frontend_input_wait else "",
        "cpu_push_frontend_output_wait": str(cpu_frontend_output_wait),
        "frontend_output_wait_reduction_percent":
            f"{100.0 * (cpu_frontend_output_wait - mem_frontend_output_wait) / cpu_frontend_output_wait:.3f}"
            if cpu_frontend_output_wait else "",
    })
  return result


def docker_make(container: str, arguments: list[str]) -> list[str]:
  return [
      "docker", "exec", "-w", str(CONTAINER_FIRMWARE), container,
      "make", *arguments,
  ]


def evaluate_profile(profile: Profile, container: str, timeout: int,
                     transfer_mode: str) -> dict[str, str]:
  results = RESULTS_ROOT / transfer_mode
  output_dir = results / profile.name
  log = output_dir / f"{profile.run}.evaluation.log"
  software = read_tier3(profile)
  stop_time = "15ms" if transfer_mode == "mem_stream" else profile.stop_time
  run_streamed(
      docker_make(container, ["clean_all"]), ROOT, log, timeout,
      f"Proposal B {transfer_mode.upper()} {profile.name} clean",
  )
  args = [
      f"ATTENTION_HEADS={profile.heads}",
      f"ATTENTION_KV_HEADS={profile.kv_heads}",
      f"ATTENTION_HEAD_DIM={profile.head_dim}",
      f"ATTENTION_CTX={profile.ctx}",
      f"EXPECTED_CHECKSUM={software['checksum']}",
      f"IMEM_SIZE={profile.imem_size}",
      f"DMEM_SIZE={profile.dmem_size}",
      f"ROM_SIZE={profile.rom_size}",
      f"RAM_SIZE={profile.ram_size}",
      f"STOP_TIME={stop_time}",
      f"TRANSFER_MODE={transfer_mode}",
      "attention-sim",
  ]
  output, wall_seconds = run_streamed(
      docker_make(container, args), ROOT, log, timeout,
      f"Proposal B {transfer_mode.upper()} {profile.name} evaluation", append=True,
  )
  result = make_result(profile, software, parse_kv(output), wall_seconds,
                       transfer_mode, stop_time)
  output_dir.mkdir(parents=True, exist_ok=True)
  with (output_dir / "result.csv").open("w", newline="", encoding="utf-8") as target:
    writer = csv.DictWriter(target, fieldnames=SUMMARY_FIELDS)
    writer.writeheader()
    writer.writerow(result)
  return result


def write_summary(rows: list[dict[str, str]], transfer_mode: str) -> Path:
  results = RESULTS_ROOT / transfer_mode
  results.mkdir(parents=True, exist_ok=True)
  path = results / "summary.csv"
  with path.open("w", newline="", encoding="utf-8") as target:
    writer = csv.DictWriter(target, fieldnames=SUMMARY_FIELDS)
    writer.writeheader()
    writer.writerows(rows)
  return path


def main() -> int:
  parser = argparse.ArgumentParser(
      description="Evaluate a Proposal B frontend against Tier 3 attention cycles."
  )
  parser.add_argument(
      "--profiles", default="board,bonsai",
      help="Comma-separated profiles: board,bonsai",
  )
  parser.add_argument("--container", default="1bit-llm-fpga-dev")
  parser.add_argument("--timeout", type=int, default=1200)
  parser.add_argument("--transfer-mode", choices=("cpu_push", "mem_stream"),
                      default="cpu_push")
  args = parser.parse_args()
  names = [name.strip() for name in args.profiles.split(",") if name.strip()]
  unknown = [name for name in names if name not in PROFILES]
  if unknown or not names:
    raise RuntimeError(f"unknown or empty profile selection: {', '.join(unknown)}")

  rows: list[dict[str, str]] = []
  try:
    for name in names:
      rows.append(evaluate_profile(PROFILES[name], args.container, args.timeout,
                                   args.transfer_mode))
  finally:
    results = RESULTS_ROOT / args.transfer_mode
    run_streamed(
        docker_make(args.container, ["clean_all"]), ROOT,
        results / "cleanup.log", args.timeout,
        f"Proposal B {args.transfer_mode.upper()} firmware cleanup",
    )

  summary = write_summary(rows, args.transfer_mode)
  print(f"[done] wrote {summary}", flush=True)
  for row in rows:
    print(
        f"[result] {row['profile']}: command_speedup={row['command_speedup']}x "
        f"active_cycle_speedup={row['active_cycle_speedup']}x "
        f"engine_utilization={row['engine_utilization_percent']}%",
        flush=True,
    )
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
