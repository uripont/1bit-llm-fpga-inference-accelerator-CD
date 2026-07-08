#!/usr/bin/env python3
"""Run Tier 3 Q1_0 x Q8_0 matvec baselines in NEORV32 simulation."""

from __future__ import annotations

import argparse
import csv
import importlib.util
import selectors
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "src" / "tier3_neorv32_cycle_kernels"
GENERATED = SRC / "generated"
RESULTS_BASE = ROOT / "results" / "tier3_neorv32_cycle_kernels" / "q1_matvec"
RESULTS = RESULTS_BASE / "board"
DEFAULT_MODEL = ROOT / "models" / "bonsai-1.7b-gguf" / "Bonsai-1.7B-Q1_0.gguf"
SIBLING_MODEL = (
    ROOT.parent
    / "1bit-llm-inference-accelerator"
    / "models"
    / "bonsai-1.7b-gguf"
    / "Bonsai-1.7B-Q1_0.gguf"
)
DEVCONTAINER_NAME = "1bit-llm-fpga-dev"
DEVCONTAINER_ROOT = Path("/workspaces/1bit-llm-fpga-inference-accelerator-CD")
DEVCONTAINER_SRC = DEVCONTAINER_ROOT / "src" / "tier3_neorv32_cycle_kernels"


@dataclass(frozen=True)
class Variant:
  name: str
  rows: int
  cols: int
  stop_time: str


@dataclass(frozen=True)
class Profile:
  name: str
  description: str
  imem_size: int
  dmem_size: int
  rom_size: str
  ram_size: str
  use_fixture: bool
  default_variants: str


DEFAULT_VARIANTS = {
    # Fast smoke test for the same Q1_0 x Q8_0 group operation. The main
    # Bonsai-shaped baseline remains q1_hidden_* below.
    "q1_group_1row": Variant("q1_group_1row", rows=1, cols=128, stop_time="5ms"),
    # Full Bonsai hidden-width row baseline. Multi-row variants test row loop
    # scaling without trying to simulate the entire 2048-row matvec.
    "q1_hidden_1row": Variant("q1_hidden_1row", rows=1, cols=2048, stop_time="10ms"),
    "q1_hidden_4row": Variant("q1_hidden_4row", rows=4, cols=2048, stop_time="30ms"),
    "q1_hidden_8row": Variant("q1_hidden_8row", rows=8, cols=2048, stop_time="60ms"),
    # FFN-down uses the wider 6144-column Bonsai shape. This needs a larger
    # simulated DMEM than the default NEORV32 testbench setting.
    "q1_ffn_down_1row": Variant("q1_ffn_down_1row", rows=1, cols=6144, stop_time="20ms"),
}

PROFILES = {
    "board": Profile(
        name="board",
        description="Tang Nano 9K-style NEORV32 memory envelope",
        imem_size=16 * 1024,
        dmem_size=8 * 1024,
        rom_size="16k",
        ram_size="8k",
        use_fixture=False,
        default_variants="q1_group_1row",
    ),
    "bonsai": Profile(
        name="bonsai",
        description="Bonsai operation-shape baseline with enlarged simulation memory",
        imem_size=256 * 1024,
        dmem_size=128 * 1024,
        rom_size="256k",
        ram_size="128k",
        use_fixture=True,
        default_variants="q1_hidden_1row",
    ),
}


SUMMARY_FIELDS = [
    "run",
    "profile",
    "mode",
    "backend",
    "kernel",
    "counter_unit",
    "rows",
    "cols",
    "q1_group",
    "q8_block",
    "dot_elements",
    "q1_groups",
    "activation_q8_blocks",
    "cycles",
    "cycles_per_row",
    "cycles_per_q1_group",
    "cycles_per_dot_element",
    "checksum",
    "stop_time",
    "dmem_size",
    "imem_size",
    "ram_size",
    "rom_size",
    "fixture",
    "measured_region",
    "q1_input_source",
    "input_mode",
]


def run(cmd: list[str], cwd: Path, log: Path, timeout: int, label: str, append: bool = False) -> str:
  print(f"[start] {label}", flush=True)
  print("+", " ".join(cmd), flush=True)
  log.parent.mkdir(parents=True, exist_ok=True)
  start = time.monotonic()
  last_progress = start
  out_parts: list[str] = []

  with log.open("a" if append else "w", encoding="utf-8") as log_file:
    proc = subprocess.Popen(cmd, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert proc.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    while True:
      events = selector.select(timeout=1.0)
      for key, _ in events:
        line = key.fileobj.readline()
        if line:
          out_parts.append(line)
          print(line, end="", flush=True)
          log_file.write(line)
          log_file.flush()

      rc = proc.poll()
      if rc is not None:
        rest = proc.stdout.read()
        if rest:
          out_parts.append(rest)
          print(rest, end="", flush=True)
          log_file.write(rest)
          log_file.flush()
        break

      now = time.monotonic()
      if now - last_progress >= 30.0:
        message = f"[progress] {label} running for {now - start:.0f}s; waiting for simulator output\n"
        print(message, end="", flush=True)
        log_file.write(message)
        log_file.flush()
        last_progress = now

      if now - start > timeout:
        proc.kill()
        raise TimeoutError(f"{label} timed out after {timeout}s")

  elapsed = time.monotonic() - start
  output = "".join(out_parts)
  if proc.returncode != 0:
    raise RuntimeError(output)
  print(f"[done] {label} ({elapsed:.1f}s)", flush=True)
  return output


def parse_kv(text: str) -> dict[str, str]:
  out = {}
  for line in text.splitlines():
    if "=" in line:
      key, value = line.strip().split("=", 1)
      if key and key[0].isalpha() and all(ch.isalnum() or ch == "_" for ch in key):
        out[key] = value
  return out


def ratio(numerator: str, denominator: str) -> str:
  den = int(denominator)
  if den == 0:
    return ""
  return f"{int(numerator) / den:.6f}"


def load_fixture_exporter():
  helper = SRC / "run-benchmark.py"
  spec = importlib.util.spec_from_file_location("tier3_benchmark_helper", helper)
  if spec is None or spec.loader is None:
    raise RuntimeError(f"cannot load fixture exporter: {helper}")
  module = importlib.util.module_from_spec(spec)
  sys.modules[spec.name] = module
  spec.loader.exec_module(module)
  return module.export_fixture


def choose_model(model_arg: Path | None) -> Path | None:
  candidates = [model_arg] if model_arg else [DEFAULT_MODEL, SIBLING_MODEL]
  for candidate in candidates:
    if candidate and candidate.exists():
      return candidate
  return None


def ensure_fixture(model_arg: Path | None, refresh: bool) -> str:
  fixture = GENERATED / "tier3_bonsai_fixture.h"
  if fixture.exists() and not refresh:
    return str(fixture.relative_to(ROOT))

  model = choose_model(model_arg)
  if model is None:
    raise RuntimeError(
        "missing GGUF model and no generated fixture is available; "
        f"looked for {DEFAULT_MODEL} and {SIBLING_MODEL}"
    )

  GENERATED.mkdir(parents=True, exist_ok=True)
  export_fixture = load_fixture_exporter()
  export_fixture(model, fixture)
  return str(fixture.relative_to(ROOT))


def selected_variants(text: str) -> list[Variant]:
  if text == "all":
    return list(DEFAULT_VARIANTS.values())

  out = []
  for name in [item.strip() for item in text.split(",") if item.strip()]:
    if name not in DEFAULT_VARIANTS:
      known = ", ".join(DEFAULT_VARIANTS)
      raise RuntimeError(f"unknown variant {name!r}; known variants: {known}")
    out.append(DEFAULT_VARIANTS[name])
  if not out:
    raise RuntimeError("no variants selected")
  return out


def find_host_ghdl() -> str | None:
  path = shutil.which("ghdl")
  if path is None:
    return None
  if not Path(path).resolve().exists():
    return None
  return path


def container_is_running(name: str) -> bool:
  if shutil.which("docker") is None:
    return False
  try:
    result = subprocess.run(
        ["docker", "ps", "--filter", f"name=^{name}$", "--format", "{{.Names}}"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
  except OSError:
    return False
  return name in {line.strip() for line in result.stdout.splitlines()}


def detect_runner(requested: str, devcontainer_name: str) -> str:
  if requested != "auto":
    return requested
  host_ghdl = find_host_ghdl()
  if shutil.which("riscv32-unknown-elf-gcc") and host_ghdl:
    return "direct"
  if container_is_running(devcontainer_name):
    return "devcontainer"
  if shutil.which("docker") and host_ghdl:
    return "docker_host_ghdl"
  if shutil.which("docker"):
    return "docker"
  raise RuntimeError("need either devcontainer toolchain or docker")


def make_args(variant: Variant,
              stop_time: str,
              dmem_size: int,
              imem_size: int,
              rom_size: str,
              ram_size: str,
              use_fixture: bool) -> list[str]:
  user_flags = " ".join([
      "-DUART0_SIM_MODE",
      f"-DQ1_ROWS={variant.rows}u",
      f"-DQ1_COLS={variant.cols}u",
      "-DQ1_PREQUANTIZED_INPUT=1",
  ])
  ghdl_flags = f"-gIMEM_SIZE={imem_size} -gDMEM_SIZE={dmem_size} --stop-time={stop_time}"
  return [
      "make",
      "NEORV32_HOME=../../neorv32-setups/neorv32",
      "RISCV_PREFIX=riscv32-unknown-elf-",
      "APP_SRC=q1_matvec.c",
      f"TIER3_USE_GGUF_FIXTURE={1 if use_fixture else 0}",
      f"TIER3_ROM_SIZE={rom_size}",
      f"TIER3_RAM_SIZE={ram_size}",
      f"USER_FLAGS_EXTRA={user_flags}",
      f"GHDL_RUN_FLAGS={ghdl_flags}",
  ]


def make_command(variant: Variant,
                 runner: str,
                 image: str,
                 platform: str,
                 stop_time: str,
                 dmem_size: int,
                 imem_size: int,
                 rom_size: str,
                 ram_size: str,
                 use_fixture: bool,
                 targets: list[str],
                 devcontainer_name: str) -> list[str]:
  args = [
      *make_args(variant, stop_time, dmem_size, imem_size, rom_size, ram_size, use_fixture),
      *targets,
  ]

  if runner == "direct":
    return args

  if runner == "devcontainer":
    return [
        "docker",
        "exec",
        "-w",
        str(DEVCONTAINER_SRC),
        devcontainer_name,
        *args,
    ]

  return [
      "docker",
      "run",
      "--rm",
      f"--platform={platform}",
      "-v",
      f"{ROOT}:/workspace",
      "-w",
      "/workspace/src/tier3_neorv32_cycle_kernels",
      image,
      *args,
  ]


def ghdl_command(stop_time: str, dmem_size: int, imem_size: int) -> list[str]:
  ghdl = find_host_ghdl()
  if ghdl is None:
    raise RuntimeError("host ghdl is not available")
  return [
      "/usr/bin/env",
      f"GHDL={ghdl}",
      str(ROOT / "neorv32-setups" / "neorv32" / "sim" / "ghdl.sh"),
      f"-gIMEM_SIZE={imem_size}",
      f"-gDMEM_SIZE={dmem_size}",
      f"--stop-time={stop_time}",
  ]


def run_build_and_sim(variant: Variant,
                      runner: str,
                      image: str,
                      platform: str,
                      stop_time: str,
                      timeout: int,
                      dmem_size: int,
                      imem_size: int,
                      rom_size: str,
                      ram_size: str,
                      use_fixture: bool,
                      log: Path,
                      devcontainer_name: str) -> str:
  if runner == "docker_host_ghdl":
    build_cmd = make_command(
        variant,
        "docker",
        image,
        platform,
        stop_time,
        dmem_size,
        imem_size,
        rom_size,
        ram_size,
        use_fixture,
        ["clean_all", "install"],
        devcontainer_name,
    )
    build_out = run(build_cmd, ROOT, log, timeout, f"q1 matvec {variant.name} build")

    sim_cmd = ghdl_command(stop_time, dmem_size, imem_size)
    sim_out = run(sim_cmd, ROOT, log, timeout, f"q1 matvec {variant.name} host-ghdl sim", append=True)
    return build_out + sim_out

  cmd = make_command(
      variant,
      runner,
      image,
      platform,
      stop_time,
      dmem_size,
      imem_size,
      rom_size,
      ram_size,
      use_fixture,
      [
      "clean_all",
      "install",
      "sim",
      ],
      devcontainer_name,
  )
  cwd = SRC if runner == "direct" else ROOT
  return run(cmd, cwd, log, timeout, f"q1 matvec {variant.name}")


def row_from_output(variant: Variant,
                    text: str,
                    profile: str,
                    stop_time: str,
                    dmem_size: int,
                    imem_size: int,
                    rom_size: str,
                    ram_size: str,
                    fixture: str) -> dict[str, str]:
  row = parse_kv(text)
  if "kernel" not in row:
    raise RuntimeError(f"{variant.name} output does not contain benchmark key/value lines")

  row["run"] = variant.name
  row["profile"] = profile
  row["mode"] = "neorv32_sim"
  row["cycles_per_row"] = ratio(row["cycles"], row["rows"])
  row["cycles_per_q1_group"] = ratio(row["cycles"], row["q1_groups"])
  row["cycles_per_dot_element"] = ratio(row["cycles"], row["dot_elements"])
  row["stop_time"] = stop_time
  row["dmem_size"] = str(dmem_size)
  row["imem_size"] = str(imem_size)
  row["ram_size"] = ram_size
  row["rom_size"] = rom_size
  row["fixture"] = fixture
  return row


def run_variant(variant: Variant,
                runner: str,
                image: str,
                platform: str,
                stop_time_override: str | None,
                timeout: int,
                dmem_size: int,
                imem_size: int,
                rom_size: str,
                ram_size: str,
                use_fixture: bool,
                profile: str,
                fixture: str,
                devcontainer_name: str) -> dict[str, str]:
  stop_time = stop_time_override or variant.stop_time
  sim_uart = ROOT / "neorv32-setups" / "neorv32" / "sim" / "tb.uart0_rx.log"
  sim_uart.parent.mkdir(parents=True, exist_ok=True)
  sim_uart.write_text("", encoding="utf-8")

  log = RESULTS / f"{variant.name}.neorv32-build.log"
  sim_output = run_build_and_sim(
      variant,
      runner,
      image,
      platform,
      stop_time,
      timeout,
      dmem_size,
      imem_size,
      rom_size,
      ram_size,
      use_fixture,
      log,
      devcontainer_name,
  )

  uart = sim_uart.read_text(encoding="utf-8", errors="replace")
  output = uart if "kernel=" in uart else sim_output
  uart_log = RESULTS / f"{variant.name}.neorv32.log"
  uart_log.write_text(output, encoding="utf-8")
  try:
    return row_from_output(variant, output, profile, stop_time, dmem_size, imem_size, rom_size, ram_size, fixture)
  except RuntimeError as exc:
    raise RuntimeError(
        f"{variant.name} completed without benchmark UART output; "
        f"increase --stop-time or inspect {uart_log}"
    ) from exc


def write_summary(rows: list[dict[str, str]]) -> Path:
  RESULTS.mkdir(parents=True, exist_ok=True)
  summary = RESULTS / "summary.csv"
  fieldnames = list(SUMMARY_FIELDS)
  for row in rows:
    for key in row:
      if key not in fieldnames:
        fieldnames.append(key)

  with summary.open("w", newline="", encoding="utf-8") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)
  return summary


def main() -> int:
  global RESULTS
  parser = argparse.ArgumentParser(description="Run Tier 3 Q1 matvec NEORV32 simulation baselines.")
  parser.add_argument("--profile", choices=sorted(PROFILES), default="board")
  parser.add_argument("--variants", default=None, help="Comma-separated variants or 'all'. Defaults depend on --profile.")
  parser.add_argument("--model", type=Path, default=None)
  parser.add_argument("--refresh-fixture", action="store_true")
  parser.add_argument("--runner", choices=["auto", "direct", "devcontainer", "docker", "docker_host_ghdl"], default="auto")
  parser.add_argument("--devcontainer-name", default=DEVCONTAINER_NAME)
  parser.add_argument("--docker-image", default="1bit-llm-fpga-dev:latest")
  parser.add_argument("--docker-platform", default="linux/amd64")
  parser.add_argument("--stop-time", default=None, help="Override per-variant GHDL stop time.")
  parser.add_argument("--timeout", type=int, default=1200, help="Wall-clock timeout per variant, in seconds.")
  parser.add_argument("--dmem-size", type=int, default=None)
  parser.add_argument("--imem-size", type=int, default=None)
  parser.add_argument("--ram-size", default=None)
  parser.add_argument("--rom-size", default=None)
  parser.add_argument("--parse-existing", action="store_true", help="Parse existing per-variant logs without rerunning simulation.")
  args = parser.parse_args()

  profile = PROFILES[args.profile]
  RESULTS = RESULTS_BASE / profile.name
  RESULTS.mkdir(parents=True, exist_ok=True)
  dmem_size = args.dmem_size or profile.dmem_size
  imem_size = args.imem_size or profile.imem_size
  ram_size = args.ram_size or profile.ram_size
  rom_size = args.rom_size or profile.rom_size
  fixture = ensure_fixture(args.model, args.refresh_fixture) if profile.use_fixture else "synthetic"
  runner = detect_runner(args.runner, args.devcontainer_name)
  variants = selected_variants(args.variants or profile.default_variants)

  print(
      f"[config] profile={profile.name} runner={runner} fixture={fixture} "
      f"imem={imem_size} dmem={dmem_size}",
      flush=True,
  )
  rows = []
  for variant in variants:
    stop_time = args.stop_time or variant.stop_time
    if args.parse_existing:
      log = RESULTS / f"{variant.name}.neorv32-build.log"
      text = log.read_text(encoding="utf-8", errors="replace")
      rows.append(row_from_output(variant, text, profile.name, stop_time, dmem_size, imem_size, rom_size, ram_size, fixture))
    else:
      rows.append(
          run_variant(
              variant,
              runner,
              args.docker_image,
              args.docker_platform,
              args.stop_time,
              args.timeout,
              dmem_size,
              imem_size,
              rom_size,
              ram_size,
              profile.use_fixture,
              profile.name,
              fixture,
              args.devcontainer_name,
          )
      )

  summary = write_summary(rows)
  print(f"[done] wrote {summary}", flush=True)
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
