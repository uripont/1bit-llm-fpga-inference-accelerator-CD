# Tang Nano 9K Gowin project

This directory creates proposal-specific synthesis projects for the NEORV32 SoC and Bonsai accelerator. It targets `GW1NR-LV9QN88PC6/I5`, enables the CFS, selects VHDL 2008, applies the board pin mapping, and constrains the input clock to 27 MHz. The Proposal A synthesis SoC keeps the CPU cycle counter and UART. Proposal B keeps the complete CFS measurement counters and one GPIO observation output while omitting UART, the CPU's duplicate architectural cycle counters, and CLINT. Its cycle evaluation is run in simulation, and the synthesis profile establishes board resource and timing feasibility without physical-board execution.

The Proposal B synthesis counters retain the 32-bit register interface and use 24-bit saturating accumulators internally. This covers the measured `ctx=2` services with more than 33 times the longest observed command-cycle count.

Gowin runs on the host and expects the pinned NEORV32 setup at the repository root. Prepare it once with:

```sh
git clone https://github.com/stnolting/neorv32-setups.git neorv32-setups
git -C neorv32-setups checkout 02646bdf8559eded9f8dcb665d9a8990b5aee4ee
git -C neorv32-setups submodule update --init --recursive
```

Open Gowin FPGA Designer Education, select the Console tab, and run:

```tcl
set bonsai_profile proposal_a
source {/absolute/path/to/src/neorv32_bonsai_accelerator/gowin/create_project.tcl}
```

Then run **Synthesize** and **Place & Route** from the Process view. Generated project files live in `build/` and are recreated from the repository sources. `proposal_a` synthesizes the common NEORV32/CFS path and Q1/Q8 engine while physically omitting the attention engine. `proposal_b_cpu_push` synthesizes the attention engine with the CPU FIFO frontend and removes the descriptor streamer, memory window, and PSRAM boundary. `proposal_b_mem_stream` replaces the CPU FIFO with the descriptor streamer and Gowin's generated DQ16 PSRAM controller. `combined` retains both engines and both frontends for integration analysis.

Create that capacity-check profile with:

```tcl
set bonsai_profile combined
source {/absolute/path/to/src/neorv32_bonsai_accelerator/gowin/create_project.tcl}
```

To create the straightforward Proposal B hardware baseline instead, run:

```tcl
set bonsai_profile proposal_b_cpu_push
source {/absolute/path/to/src/neorv32_bonsai_accelerator/gowin/create_project.tcl}
```

The board implementation profile supports the evaluated attention shapes with head dimension up to 32, one KV head, and two locally stored scores, matching the two Tier 3 compatibility fixtures used for Proposal B evaluation.

To create the descriptor-driven Proposal B profile, run:

```tcl
set bonsai_profile proposal_b_mem_stream
source {/absolute/path/to/src/neorv32_bonsai_accelerator/gowin/create_project.tcl}
```

This profile uses the generated IP under `ip/`: a 27-to-54 MHz PLL and the
single-channel Gowin PSRAM HS controller configured for DQ16, 64-bit user
beats, 32-byte bursts, and six-cycle initial latency. The adapter enforces the
controller's 18-cycle minimum interval between burst commands.

## Proposal A result

Gowin FPGA Designer Education V1.9.11.03 successfully places and routes the `proposal_a` profile for `GW1NR-LV9QN88PC6/I5` at the board's 27 MHz clock. The final timing report gives 32.678 MHz Fmax with zero setup and hold violations. Routed resource use is 6,758/8,640 logic elements (79%), 3,329/6,693 registers (50%), 16/26 BSRAM blocks (62%), and 8/10 DSP blocks (80%).

The Q1 engine reduces four signed lanes per cycle; this keeps the operation contract unchanged while meeting the board clock. The `combined` profile is an integration check containing both reduced engines and shared frontends. Gowin maps it to 16,830/8,640 logic elements (195%) and stops at the capacity check. Each proposal therefore has its own synthesis configuration for board-feasibility assessment. Raw combined evidence is preserved at `results/gowin_synthesis/combined/synthesis.log`.

## Proposal B CPU push result

Gowin FPGA Designer Education V1.9.11.03 successfully places and routes the `proposal_b_cpu_push` profile at 27 MHz. The final timing report gives 28.377 MHz Fmax with zero setup and hold violations. Routed resource use is 7,890/8,640 logic elements (92%), 4,331/6,693 registers (65%), 10/26 BSRAM blocks (39%), and three `MULT18X18` plus two `MULTADDALU18X18` DSP primitives. The profile implements the selected `ctx=2` attention operation, a one-word CPU ingress/egress FIFO, and the full CFS measurement categories. MEM_STREAM logic and its PSRAM boundary are absent from this bitstream.

## Proposal B MEM_STREAM result

Gowin FPGA Designer Education V1.9.11.03 successfully analyzes and maps the `proposal_b_mem_stream` profile, including the NEORV32 SoC, attention engine, descriptor streamer, generated PLL, and generated DQ16 PSRAM controller. The mapped design requires 11,578/8,640 logic elements (134%). Gowin therefore stops synthesis at the device-capacity check, before place and route, so this profile has no routed timing result.

The CPU FIFO and software memory aperture are physically absent from this profile. Its capacity failure therefore applies to the intended MEM_STREAM-only implementation rather than a build containing both data paths. Together with the routed CPU_PUSH result, this establishes that Proposal B's implemented `ctx=2` attention engine fits the Tang Nano 9K with CPU_PUSH, while adding Gowin's DQ16 PSRAM controller and descriptor path exceeds the remaining logic capacity.
