# NEORV32 Bonsai Accelerator

This directory contains the project-owned RTL and firmware for the hardware
accelerator described in `docs/02-bonsai-accelerator-hardware-blueprint.pdf`.
The upstream NEORV32 submodule remains unchanged.

The current implementation establishes the CFS identity, interface version,
shared register map, service and transfer identifiers, semantic tile roles,
command lifecycle, and per-command counters. A temporary streaming engine
requests a four-word input transaction and produces a four-word output
transaction. The `CPU_PUSH`
frontend provides independent ingress and egress FIFOs, request metadata,
backpressure, physical-byte counters, and frontend wait counters. Local tile
buffers and the two compute engines are added in subsequent stages;
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
counter identity and FIFO payloads, acknowledges repeated commands, and checks
the current `MEM_STREAM` error behavior.
