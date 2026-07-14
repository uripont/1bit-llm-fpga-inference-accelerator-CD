# NEORV32 Bonsai Accelerator

This directory contains the project-owned RTL and firmware for the hardware
accelerator described in `docs/02-bonsai-accelerator-hardware-blueprint.pdf`.
The upstream NEORV32 submodule remains unchanged.

The current implementation establishes the CFS identity, interface version,
shared register map, service and transfer identifiers, semantic tile roles,
command lifecycle, and per-command counters. Proposal A now has a board-sized
transport contract for one 128-element Q1_0 by Q8_0 work unit. It transfers
four Q8 blocks, one packed Q1 group, and one row result through role-tagged
tiles. The board-work-unit engine unpacks the records, performs one signed lane
per cycle, applies both fixed-point scales, accumulates the row, and emits a
saturated signed 16-bit result. The `CPU_PUSH` frontend provides independent
ingress and egress FIFOs, request metadata,
backpressure, physical-byte counters, and frontend wait counters. Local tile
buffers now stage complete role-tagged input and output transactions between
the FIFOs and engine. The two compute engines are added in subsequent stages;
`MEM_STREAM` currently terminates with an unsupported-mode error.

## Validate the CFS integration

Run inside the project Dev Container:

```sh
cd src/neorv32_bonsai_accelerator/sw/shell_probe
make clean_all shell-sim
```

The command builds the probe firmware, compiles the complete NEORV32 testbench
with the project CFS implementation, and checks for `shell_probe=PASS` in the
simulated UART output. The probe runs both service selections, validates the
Q1/Q8 tile sequence and deterministic fixture, checks counter identity and FIFO
payloads, acknowledges repeated commands, and checks the current `MEM_STREAM`
error behavior. The two-word FIFOs exercise CPU-side backpressure, while local
tiles keep the engines independent of CPU drain timing.
