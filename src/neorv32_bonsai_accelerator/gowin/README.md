# Tang Nano 9K Gowin project

This directory creates proposal-specific synthesis projects for the NEORV32
SoC and Bonsai accelerator. It targets
`GW1NR-LV9QN88PC6/I5`, enables the CFS, selects VHDL 2008, applies the board
pin mapping, and constrains the input clock to 27 MHz.
The synthesis SoC keeps the CPU cycle counter and UART while omitting CLINT,
which the accelerator evaluation firmware does not use.

Open Gowin FPGA Designer Education, select the Console tab, and run:

```tcl
set bonsai_profile proposal_a
source {/absolute/path/to/src/neorv32_bonsai_accelerator/gowin/create_project.tcl}
```

Then run **Synthesize** and **Place & Route** from the Process view. Generated
project files live in `build/` and are recreated from the repository sources.

`stream_memory_boundary.vhd` keeps the PSRAM controller boundary inactive for
this setup checkpoint. The controller integration replaces this file in the
PSRAM checkpoint.

`proposal_a` synthesizes the common NEORV32/CFS path and Q1/Q8 engine while
physically omitting the attention engine. `combined` retains both engines for
integration analysis.

The board implementation profile supports the evaluated attention shapes with
head dimension up to 32, one KV head, and 128 locally stored scores.

## Proposal A result

Gowin FPGA Designer Education V1.9.11.03 successfully places and routes the
`proposal_a` profile for `GW1NR-LV9QN88PC6/I5` at the board's 27 MHz clock.
The final timing report gives 30.610 MHz Fmax with zero setup and hold
violations. Routed resource use is 6,970/8,640 logic elements (81%),
3,352/6,693 registers (51%), 16/26 BSRAM blocks (62%), and 8/10 DSP blocks
(80%). The Q1 engine reduces four signed lanes per cycle; this keeps the
operation contract unchanged while meeting the board clock.

The `combined` profile is an integration check. Its monolithic mapping uses
32,162 logic elements against 8,640 available, so each proposal has its own
synthesis configuration for board-feasibility assessment.
