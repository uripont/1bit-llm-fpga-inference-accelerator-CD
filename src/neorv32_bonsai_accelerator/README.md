# NEORV32 Bonsai Accelerator

This directory contains the project-owned RTL and firmware for the hardware
accelerator described in `docs/02-bonsai-accelerator-hardware-blueprint.pdf`.
The upstream NEORV32 submodule remains unchanged.

The current implementation establishes the CFS identity, interface version,
shared register map, service and transfer identifiers, semantic tile roles, and
configuration readback. Command execution, counters, CPU-push data movement,
local buffers, and the two compute engines are added in subsequent stages.

## Validate the CFS integration

Run inside the project Dev Container:

```sh
cd src/neorv32_bonsai_accelerator/sw/shell_probe
make clean_all shell-sim
```

The command builds the probe firmware, compiles the complete NEORV32 testbench
with the project CFS implementation, and checks for `shell_probe=PASS` in the
simulated UART output.

