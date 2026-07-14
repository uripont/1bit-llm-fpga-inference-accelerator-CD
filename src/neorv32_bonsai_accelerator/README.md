# NEORV32 Bonsai Accelerator

This directory contains the project-owned RTL and firmware for the hardware
accelerator described in `docs/02-bonsai-accelerator-hardware-blueprint.pdf`.
The upstream NEORV32 submodule remains unchanged.

The current implementation establishes the CFS identity, interface version,
shared register map, service and transfer identifiers, semantic tile roles,
command lifecycle, and per-command counters. Proposal A now has a board-sized
transport contract for Q1_0 by Q8_0 rows. The matvec engine streams configured
rows of 128-element groups, reduces 32 sign-controlled Q8 lanes per block,
applies the Q1 and Q8 scales in separate pipeline stages, preserves a 64-bit
accumulator across groups, and emits one saturated signed 16-bit result per
row. It accepts raw FP16 scales for GGUF rows and signed fixed-Q8 scales for the
Tier 3 synthetic board fixture. `CPU_PUSH` deliberately resends the Q8 vector
for every row; activation reuse is deferred to the future `MEM_STREAM` path.
The `CPU_PUSH` frontend provides independent ingress and egress FIFOs, request metadata,
backpressure, physical-byte counters, and frontend wait counters. Local tile
buffers stage complete role-tagged input and output transactions between the
FIFOs and engine. The attention/KV engine and `MEM_STREAM` remain subsequent
stages; `MEM_STREAM` currently terminates with an unsupported-mode error.

## Validate the CFS integration

Run inside the project Dev Container:

```sh
cd src/neorv32_bonsai_accelerator/sw/shell_probe
make clean_all shell-sim
```

The command builds the probe firmware, compiles the complete NEORV32 testbench
with the project CFS implementation, and checks for `shell_probe=PASS` in the
simulated UART output. The probe runs both service selections, validates the
Q1/Q8 tile sequence and deterministic fixtures, including a 16-group,
2048-element row and a multi-row command, checks counter identity and FIFO
payloads, acknowledges repeated commands, and checks the current `MEM_STREAM`
error behavior. The two-word FIFOs exercise CPU-side backpressure, while local
tiles keep the engines independent of CPU drain timing.

## Check Proposal A synthesis

```sh
cd src/neorv32_bonsai_accelerator
./sim/check-q1-synth.sh
```

The dedicated firmware under `sw/q1_matvec_benchmark/` is ready for the Tier 3
board and Bonsai compatibility profiles. It uses the same packed synthetic or
GGUF inputs and emits parseable command, engine, wait, traffic, work, and
checksum fields. The benchmark runner and result generation are the next stage.
