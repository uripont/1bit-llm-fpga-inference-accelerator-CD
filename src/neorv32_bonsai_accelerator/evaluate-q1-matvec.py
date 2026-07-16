#!/usr/bin/env python3
"""Evaluate Proposal A against the Tier 3 NEORV32 software baselines."""

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
FIRMWARE = ACCEL / "sw" / "q1_matvec_evaluation"
RESULTS = ROOT / "results" / "proposal_a_evaluation" / "q1_matvec"
CONTAINER_ROOT = Path("/workspaces/1bit-llm-fpga-inference-accelerator-CD")
CONTAINER_FIRMWARE = CONTAINER_ROOT / "src" / "neorv32_bonsai_accelerator" / "sw" / "q1_matvec_evaluation"


@dataclass(frozen=True)
class Profile:
  name: str
  run: str
  rows: int
  cols: int
  fixture: bool
  imem_size: int
  dmem_size: int
  rom_size: str
  ram_size: str
  stop_time: str
  tier3_csv: Path


PROFILES = {
    "board": Profile(
        name="board",
        run="q1_group_1row",
        rows=1,
        cols=128,
        fixture=False,
        imem_size=16 * 1024,
        dmem_size=8 * 1024,
        rom_size="16k",
        ram_size="8k",
        stop_time="5ms",
        tier3_csv=ROOT / "results" / "tier3_neorv32_cycle_kernels" /
        "q1_matvec" / "board" / "summary.csv",
    ),
    "bonsai": Profile(
        name="bonsai",
        run="q1_hidden_1row",
        rows=1,
        cols=2048,
        fixture=True,
        imem_size=256 * 1024,
        dmem_size=128 * 1024,
        rom_size="256k",
        ram_size="128k",
        stop_time="10ms",
        tier3_csv=ROOT / "results" / "tier3_neorv32_cycle_kernels" /
        "q1_matvec" / "bonsai" / "summary.csv",
    ),
}


SUMMARY_FIELDS = [
    "run",
    "profile",
    "rows",
    "cols",
    "q1_groups",
    "dot_elements",
    "q1_input_source",
    "q1_scale_format",
    "transfer_mode",
    "cpu_push_strategy",
    "software_cycles",
    "command_cycles",
    "engine_cycles",
    "active_cycles",
    "arithmetic_pipeline_cycles",
    "input_wait_cycles",
    "output_wait_cycles",
    "control_cycles",
    "frontend_input_wait",
    "frontend_output_wait",
    "input_bytes",
    "output_bytes",
    "work_groups",
    "software_cycles_per_group",
    "command_cycles_per_group",
    "active_cycles_per_group",
    "command_speedup",
    "engine_speedup",
    "active_cycle_speedup",
    "command_cycle_reduction_percent",
    "engine_utilization_percent",
    "engine_input_wait_percent",
    "checksum",
    "expected_checksum",
    "evaluation_status",
    "simulation_wall_seconds",
    "stop_time",
]


def run_streamed(cmd: list[str], cwd: Path, log: Path, timeout: int, label: str,
                 append: bool = False) -> tuple[str, float]:
  print(f"[start] {label}", flush=True)
  print("+", " ".join(cmd), flush=True)
  log.parent.mkdir(parents=True, exist_ok=True)
  started = time.monotonic()
  last_progress = started
  parts: list[str] = []

  with log.open("a" if append else "w", encoding="utf-8") as log_file:
    proc = subprocess.Popen(
        cmd, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
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
      "rows": str(profile.rows),
      "cols": str(profile.cols),
      "q1_group": software["q1_group"],
      "q8_block": software["q8_block"],
      "dot_elements": software["dot_elements"],
      "q1_groups": software["q1_groups"],
      "activation_q8_blocks": software["activation_q8_blocks"],
      "q1_input_source": software["q1_input_source"],
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
                hardware: dict[str, str], wall_seconds: float) -> dict[str, str]:
  validate_compatibility(profile, software, hardware)
  sw = int(software["cycles"])
  command = int(hardware["command_cycles"])
  engine = int(hardware["engine_cycles"])
  active = int(hardware["active_cycles"])
  groups = int(hardware["q1_groups"])
  input_wait = int(hardware["input_wait_cycles"])

  result = {key: hardware.get(key, "") for key in SUMMARY_FIELDS}
  result.update({
      "run": profile.run,
      "profile": profile.name,
      "software_cycles": str(sw),
      # Each group has four blocks: eight reduction steps, scale, accumulate.
      "arithmetic_pipeline_cycles": str(groups * 4 * 10),
      "software_cycles_per_group": quotient(sw, groups),
      "command_cycles_per_group": quotient(command, groups),
      "active_cycles_per_group": quotient(active, groups),
      "command_speedup": quotient(sw, command),
      "engine_speedup": quotient(sw, engine),
      "active_cycle_speedup": quotient(sw, active),
      "command_cycle_reduction_percent": f"{100.0 * (sw - command) / sw:.3f}",
      "engine_utilization_percent": percent(active, engine),
      "engine_input_wait_percent": percent(input_wait, engine),
      "simulation_wall_seconds": f"{wall_seconds:.3f}",
      "stop_time": profile.stop_time,
  })
  return result


def docker_make(container: str, arguments: list[str]) -> list[str]:
  return [
      "docker", "exec", "-w", str(CONTAINER_FIRMWARE), container,
      "make", *arguments,
  ]


def evaluate_profile(profile: Profile, container: str, timeout: int) -> dict[str, str]:
  output_dir = RESULTS / profile.name
  log = output_dir / f"{profile.run}.evaluation.log"
  software = read_tier3(profile)
  run_streamed(
      docker_make(container, ["clean_all"]), ROOT, log, timeout,
      f"Proposal A {profile.name} clean",
  )
  args = [
      f"Q1_ROWS={profile.rows}",
      f"Q1_COLS={profile.cols}",
      f"TIER3_USE_GGUF_FIXTURE={1 if profile.fixture else 0}",
      f"EXPECTED_CHECKSUM={software['checksum']}",
      f"IMEM_SIZE={profile.imem_size}",
      f"DMEM_SIZE={profile.dmem_size}",
      f"ROM_SIZE={profile.rom_size}",
      f"RAM_SIZE={profile.ram_size}",
      f"STOP_TIME={profile.stop_time}",
      "q1-sim",
  ]
  output, wall_seconds = run_streamed(
      docker_make(container, args), ROOT, log, timeout,
      f"Proposal A {profile.name} evaluation", append=True,
  )
  hardware = parse_kv(output)
  result = make_result(profile, software, hardware, wall_seconds)

  output_dir.mkdir(parents=True, exist_ok=True)
  with (output_dir / "result.csv").open("w", newline="", encoding="utf-8") as target:
    writer = csv.DictWriter(target, fieldnames=SUMMARY_FIELDS)
    writer.writeheader()
    writer.writerow(result)
  return result


def write_summary(rows: list[dict[str, str]]) -> Path:
  RESULTS.mkdir(parents=True, exist_ok=True)
  path = RESULTS / "summary.csv"
  with path.open("w", newline="", encoding="utf-8") as target:
    writer = csv.DictWriter(target, fieldnames=SUMMARY_FIELDS)
    writer.writeheader()
    writer.writerows(rows)
  return path


def merge_existing_results(rows: list[dict[str, str]]) -> list[dict[str, str]]:
  by_profile: dict[str, dict[str, str]] = {}
  for profile in PROFILES.values():
    path = RESULTS / profile.name / "result.csv"
    if path.is_file():
      with path.open(newline="", encoding="utf-8") as source:
        existing = list(csv.DictReader(source))
      if len(existing) == 1:
        by_profile[profile.name] = existing[0]
  for row in rows:
    by_profile[row["profile"]] = row
  return [by_profile[name] for name in PROFILES if name in by_profile]


def main() -> int:
  parser = argparse.ArgumentParser(
      description="Evaluate Proposal A against matching Tier 3 software cycles."
  )
  parser.add_argument(
      "--profiles", default="board,bonsai",
      help="Comma-separated profiles: board,bonsai",
  )
  parser.add_argument("--container", default="1bit-llm-fpga-dev")
  parser.add_argument("--timeout", type=int, default=1200)
  args = parser.parse_args()

  names = [name.strip() for name in args.profiles.split(",") if name.strip()]
  unknown = [name for name in names if name not in PROFILES]
  if unknown or not names:
    raise RuntimeError(f"unknown or empty profile selection: {', '.join(unknown)}")

  rows = []
  try:
    for name in names:
      rows.append(evaluate_profile(PROFILES[name], args.container, args.timeout))
  finally:
    run_streamed(
        docker_make(args.container, ["clean_all"]), ROOT,
        RESULTS / "cleanup.log", args.timeout, "Proposal A firmware cleanup",
    )

  summary_rows = merge_existing_results(rows)
  summary = write_summary(summary_rows)
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
