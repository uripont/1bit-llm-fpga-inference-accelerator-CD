#!/usr/bin/env python3
"""Run Tier 3 attention/KV software baselines in NEORV32 simulation."""

from __future__ import annotations

import argparse
import csv
import selectors
import shutil
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "src" / "tier3_neorv32_cycle_kernels"
RESULTS_BASE = ROOT / "results" / "tier3_neorv32_cycle_kernels" / "attention_kv"
RESULTS = RESULTS_BASE / "board"
DEVCONTAINER_NAME = "1bit-llm-fpga-dev"
DEVCONTAINER_ROOT = Path("/workspaces/1bit-llm-fpga-inference-accelerator-CD")
DEVCONTAINER_SRC = DEVCONTAINER_ROOT / "src" / "tier3_neorv32_cycle_kernels"
NORM_MODES = {
    "softmax_exact": "ATTENTION_NORM_SOFTMAX_EXACT",
}


@dataclass(frozen=True)
class Variant:
  name: str
  heads: int
  kv_heads: int
  head_dim: int
  ctx: int
  stop_time: str


@dataclass(frozen=True)
class Profile:
  name: str
  description: str
  imem_size: int
  dmem_size: int
  rom_size: str
  ram_size: str
  default_variants: str


DEFAULT_VARIANTS = {
    # Board-sized service-call tile: same append, score, softmax, and value
    # phases, but with a compact head tile so it fits the small NEORV32 memory
    # and reaches UART output in a practical simulation time.
    "kv_tile_ctx2": Variant("kv_tile_ctx2", heads=1, kv_heads=1, head_dim=32, ctx=2, stop_time="20ms"),
    # Bonsai-style grouped-query tile: multiple query heads share one KV head.
    # This keeps the real backend phases and GQA mapping while staying runnable.
    "kv_bonsai_gqa_ctx2": Variant("kv_bonsai_gqa_ctx2", heads=2, kv_heads=1, head_dim=16, ctx=2, stop_time="20ms"),
    # Full Bonsai reduced-context operation shape. Kept for explicit scaling
    # experiments; it is too slow for the default first-pass NEORV32 run.
    "kv_bonsai_full_ctx4": Variant("kv_bonsai_full_ctx4", heads=16, kv_heads=8, head_dim=128, ctx=4, stop_time="80ms"),
}

PROFILES = {
    "board": Profile(
        name="board",
        description="Tang Nano 9K-style NEORV32 memory envelope",
        imem_size=16 * 1024,
        dmem_size=8 * 1024,
        rom_size="16k",
        ram_size="8k",
        default_variants="kv_tile_ctx2",
    ),
    "bonsai": Profile(
        name="bonsai",
        description="Bonsai operation-shape baseline with enlarged simulation memory",
        imem_size=256 * 1024,
        dmem_size=128 * 1024,
        rom_size="256k",
        ram_size="128k",
        default_variants="kv_bonsai_gqa_ctx2",
    ),
}


SUMMARY_FIELDS = [
    "run",
    "profile",
    "mode",
    "backend",
    "kernel",
    "baseline_role",
    "counter_unit",
    "phase_cycles_role",
    "normalization_mode",
    "heads",
    "kv_heads",
    "head_dim",
    "ctx",
    "repeats",
    "score_mac",
    "value_mac",
    "softmax_elements",
    "k_read_elements",
    "v_read_elements",
    "kv_append_elements",
    "kv_cache_elements",
    "k_read_bytes",
    "v_read_bytes",
    "kv_read_bytes",
    "kv_write_bytes",
    "kv_total_bytes",
    "append_cycles",
    "score_cycles",
    "norm_cycles",
    "value_cycles",
    "service_cycles",
    "cycles",
    "service_cycles_per_ctx",
    "cycles_per_k_read_byte",
    "cycles_per_v_read_byte",
    "cycles_per_kv_read_byte",
    "cycles_per_kv_write_byte",
    "cycles_per_kv_total_byte",
    "score_cycles_per_k_read_byte",
    "value_cycles_per_v_read_byte",
    "cycles_per_score_mac",
    "cycles_per_value_mac",
    "cycles_per_softmax_element",
    "checksum",
    "stop_time",
    "dmem_size",
    "imem_size",
    "ram_size",
    "rom_size",
    "measured_region",
    "input_source",
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


def inv_sqrt_head_dim(head_dim: int) -> str:
  known = {
      16: "0.25f",
      32: "0.1767766952966369f",
      64: "0.125f",
      128: "0.08838834764831845f",
  }
  if head_dim not in known:
    raise RuntimeError(f"no ATTENTION_INV_SQRT_HEAD_DIM constant for head_dim={head_dim}")
  return known[head_dim]


def make_args(variant: Variant,
              norm_mode: str,
              stop_time: str,
              dmem_size: int,
              imem_size: int,
              rom_size: str,
              ram_size: str) -> list[str]:
  user_flags = " ".join([
      "-DUART0_SIM_MODE",
      f"-DATTENTION_HEADS={variant.heads}u",
      f"-DATTENTION_KV_HEADS={variant.kv_heads}u",
      f"-DATTENTION_HEAD_DIM={variant.head_dim}u",
      f"-DATTENTION_CTX={variant.ctx}u",
      f"-DATTENTION_INV_SQRT_HEAD_DIM={inv_sqrt_head_dim(variant.head_dim)}",
      f"-DATTENTION_NORM_MODE={NORM_MODES[norm_mode]}",
      "-DATTENTION_REPEATS=1u",
  ])
  ghdl_flags = f"-gIMEM_SIZE={imem_size} -gDMEM_SIZE={dmem_size} --stop-time={stop_time}"
  return [
      "make",
      "NEORV32_HOME=../../neorv32-setups/neorv32",
      "RISCV_PREFIX=riscv32-unknown-elf-",
      "APP_SRC=attention_scan.c",
      "TIER3_USE_GGUF_FIXTURE=0",
      f"TIER3_ROM_SIZE={rom_size}",
      f"TIER3_RAM_SIZE={ram_size}",
      f"USER_FLAGS_EXTRA={user_flags}",
      f"GHDL_RUN_FLAGS={ghdl_flags}",
  ]


def make_command(variant: Variant,
                 norm_mode: str,
                 runner: str,
                 image: str,
                 platform: str,
                 stop_time: str,
                 dmem_size: int,
                 imem_size: int,
                 rom_size: str,
                 ram_size: str,
                 targets: list[str],
                 devcontainer_name: str) -> list[str]:
  args = [
      *make_args(variant, norm_mode, stop_time, dmem_size, imem_size, rom_size, ram_size),
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
                      norm_mode: str,
                      runner: str,
                      image: str,
                      platform: str,
                      stop_time: str,
                      timeout: int,
                      dmem_size: int,
                      imem_size: int,
                      rom_size: str,
                      ram_size: str,
                      log: Path,
                      devcontainer_name: str) -> str:
  if runner == "docker_host_ghdl":
    build_cmd = make_command(
        variant,
        norm_mode,
        "docker",
        image,
        platform,
        stop_time,
        dmem_size,
        imem_size,
        rom_size,
        ram_size,
        ["clean_all", "install"],
        devcontainer_name,
    )
    build_out = run(build_cmd, ROOT, log, timeout, f"attention KV {variant.name} {norm_mode} build")

    sim_cmd = ghdl_command(stop_time, dmem_size, imem_size)
    sim_out = run(sim_cmd, ROOT, log, timeout, f"attention KV {variant.name} {norm_mode} host-ghdl sim", append=True)
    return build_out + sim_out

  cmd = make_command(
      variant,
      norm_mode,
      runner,
      image,
      platform,
      stop_time,
      dmem_size,
      imem_size,
      rom_size,
      ram_size,
      ["clean_all", "install", "sim"],
      devcontainer_name,
  )
  cwd = SRC if runner == "direct" else ROOT
  return run(cmd, cwd, log, timeout, f"attention KV {variant.name} {norm_mode}")


def row_from_output(variant: Variant,
                    norm_mode: str,
                    text: str,
                    profile: str,
                    stop_time: str,
                    dmem_size: int,
                    imem_size: int,
                    rom_size: str,
                    ram_size: str) -> dict[str, str]:
  row = parse_kv(text)
  if "kernel" not in row:
    raise RuntimeError(f"{variant.name} output does not contain benchmark key/value lines")

  row["run"] = f"{variant.name}_{norm_mode}"
  row["profile"] = profile
  row["mode"] = "neorv32_sim"
  row["service_cycles_per_ctx"] = ratio(row["service_cycles"], row["ctx"])
  row["cycles_per_k_read_byte"] = ratio(row["service_cycles"], row["k_read_bytes"])
  row["cycles_per_v_read_byte"] = ratio(row["service_cycles"], row["v_read_bytes"])
  row["cycles_per_kv_read_byte"] = ratio(row["service_cycles"], row["kv_read_bytes"])
  row["cycles_per_kv_write_byte"] = ratio(row["service_cycles"], row["kv_write_bytes"])
  row["cycles_per_kv_total_byte"] = ratio(row["service_cycles"], row["kv_total_bytes"])
  row["score_cycles_per_k_read_byte"] = ratio(row["score_cycles"], row["k_read_bytes"])
  row["value_cycles_per_v_read_byte"] = ratio(row["value_cycles"], row["v_read_bytes"])
  row["cycles_per_score_mac"] = ratio(row["score_cycles"], row["score_mac"])
  row["cycles_per_value_mac"] = ratio(row["value_cycles"], row["value_mac"])
  row["cycles_per_softmax_element"] = ratio(row["norm_cycles"], row["softmax_elements"])
  row["stop_time"] = stop_time
  row["dmem_size"] = str(dmem_size)
  row["imem_size"] = str(imem_size)
  row["ram_size"] = ram_size
  row["rom_size"] = rom_size
  return row


def run_variant(variant: Variant,
                norm_mode: str,
                runner: str,
                image: str,
                platform: str,
                stop_time_override: str | None,
                timeout: int,
                dmem_size: int,
                imem_size: int,
                rom_size: str,
                ram_size: str,
                profile: str,
                devcontainer_name: str) -> dict[str, str]:
  stop_time = stop_time_override or variant.stop_time
  sim_uart = ROOT / "neorv32-setups" / "neorv32" / "sim" / "tb.uart0_rx.log"
  sim_uart.parent.mkdir(parents=True, exist_ok=True)
  sim_uart.write_text("", encoding="utf-8")

  run_name = f"{variant.name}_{norm_mode}"
  log = RESULTS / f"{run_name}.neorv32-build.log"
  sim_output = run_build_and_sim(
      variant,
      norm_mode,
      runner,
      image,
      platform,
      stop_time,
      timeout,
      dmem_size,
      imem_size,
      rom_size,
      ram_size,
      log,
      devcontainer_name,
  )

  uart = sim_uart.read_text(encoding="utf-8", errors="replace")
  output = uart if "kernel=" in uart else sim_output
  uart_log = RESULTS / f"{run_name}.neorv32.log"
  uart_log.write_text(output, encoding="utf-8")
  try:
    return row_from_output(variant, norm_mode, output, profile, stop_time, dmem_size, imem_size, rom_size, ram_size)
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
  parser = argparse.ArgumentParser(description="Run Tier 3 attention/KV NEORV32 simulation baselines.")
  parser.add_argument("--profile", choices=sorted(PROFILES), default="board")
  parser.add_argument("--variants", default=None, help="Comma-separated variants or 'all'. Defaults depend on --profile.")
  parser.add_argument("--norm-modes", default="softmax_exact", help="Comma-separated normalization modes. Default: softmax_exact.")
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
  runner = detect_runner(args.runner, args.devcontainer_name)
  variants = selected_variants(args.variants or profile.default_variants)
  if args.norm_modes == "all":
    norm_modes = list(NORM_MODES)
  else:
    norm_modes = [item.strip() for item in args.norm_modes.split(",") if item.strip()]
  unknown_modes = [mode for mode in norm_modes if mode not in NORM_MODES]
  if unknown_modes:
    known = ", ".join(NORM_MODES)
    raise RuntimeError(f"unknown normalization modes {unknown_modes}; known modes: {known}")

  print(
      f"[config] profile={profile.name} runner={runner} "
      f"imem={imem_size} dmem={dmem_size} norm_modes={','.join(norm_modes)}",
      flush=True,
  )
  rows = []
  for variant in variants:
    stop_time = args.stop_time or variant.stop_time
    for norm_mode in norm_modes:
      if args.parse_existing:
        log = RESULTS / f"{variant.name}_{norm_mode}.neorv32.log"
        text = log.read_text(encoding="utf-8", errors="replace")
        rows.append(row_from_output(variant, norm_mode, text, profile.name, stop_time, dmem_size, imem_size, rom_size, ram_size))
      else:
        rows.append(
            run_variant(
                variant,
                norm_mode,
                runner,
                args.docker_image,
                args.docker_platform,
                args.stop_time,
                args.timeout,
                dmem_size,
                imem_size,
                rom_size,
                ram_size,
                profile.name,
                args.devcontainer_name,
            )
        )

  summary = write_summary(rows)
  print(f"[done] wrote {summary}", flush=True)
  return 0


if __name__ == "__main__":
  raise SystemExit(main())
