# NEORV32 Bonsai Accelerator

This directory contains the project-owned RTL and firmware for the hardware accelerator described in `docs/02-bonsai-accelerator-hardware-blueprint.pdf`. The upstream NEORV32 submodule remains unchanged.

The reproducible Tang Nano 9K Gowin projects and their synthesis results are documented in `gowin/README.md`.

## Validate the CFS integration

Run inside the project Dev Container:

```sh
cd src/neorv32_bonsai_accelerator/sw/shell_probe
make clean_all shell-sim
```

The command builds the probe firmware, compiles the complete NEORV32 testbench with the project CFS implementation, and checks for `shell_probe=PASS` in the simulated UART output. The probe runs both service selections, validates the Q1/Q8 tile sequence and deterministic fixtures, including a 16-group, 2048-element row and a multi-row command, checks counter identity and FIFO payloads, acknowledges repeated commands, checks both attention compatibility shapes, their role-tagged tile sequences, GQA mapping, complete attention output vectors, invalid-shape rejection, and the disabled-`MEM_STREAM` error behavior. The two-word FIFOs exercise CPU-side backpressure, while local tiles keep the engines independent of CPU drain timing.

## Check Proposal A synthesis

```sh
cd src/neorv32_bonsai_accelerator
./sim/check-q1-synth.sh
```

## Evaluate Proposal A

The dedicated firmware under `sw/q1_matvec_evaluation/` uses the Tier 3 board and Bonsai compatibility inputs and emits command, engine, wait, traffic, work, and checksum fields. Run both profiles from the repository root with:

```sh
python3 src/neorv32_bonsai_accelerator/evaluate-q1-matvec.py
```

The evaluation compares complete `CPU_PUSH` command cycles and engine-active cycles with the corresponding Tier 3 software cycles. Logs and summaries are written under `results/proposal_a_evaluation/q1_matvec/`.

## Evaluate Proposal B CPU push

The dedicated firmware under `sw/attention_kv_evaluation/` uses the Tier 3 board and GQA compatibility fixtures. It prepares all payloads before launch, services each requested tile with a tight MMIO burst, validates append writeback, the weighted output checksum, traffic, work, and cycle identities, and reports hardware-owned cycles, waits, and transaction counts. The shell probe separately compares every signed-16 output element with the fixed-point software reference. Run both profiles from the repository root with:

```sh
python3 src/neorv32_bonsai_accelerator/evaluate-attention-kv-cpu-push.py
```

Logs and summaries are written under
`results/proposal_b_evaluation/attention_kv/cpu_push/`. 

## Evaluate Proposal B MEM_STREAM

`MEM_STREAM` uses role-indexed descriptors to move Q/K/V and output tiles between backing memory and the same attention engine. The simulation memory aperture is loaded before command timing. Timed transfers use a behavioral model of the Gowin PSRAM HS controller's user-side interface configured for the Tang Nano 9K: physical DQ16, 64-bit user beats, 32-byte bursts, a fixed-latency setting of six, and an 18-user-clock minimum command interval. The controller user clock shares the 27 MHz system-clock domain, corresponding to a 54 MHz memory clock at the IP's 1:2 ratio. Initialization gates requests before fixture execution; physical pins and electrical timing remain outside this controller-level simulation.

```sh
python3 src/neorv32_bonsai_accelerator/evaluate-attention-kv-mem-stream.py
```

Results are written under `results/proposal_b_evaluation/attention_kv/mem_stream/` and include direct command-cycle and frontend-wait comparisons with CPU push.

The integration synthesis profile containing both reduced engines and shared frontends would require 16,830/8,640 logic elements. Raw proposal-specific and combined synthesis evidence is preserved under `results/gowin_synthesis/`.
