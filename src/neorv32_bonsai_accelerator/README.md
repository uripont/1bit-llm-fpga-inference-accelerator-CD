# NEORV32 Bonsai Accelerator

This directory contains the project-owned RTL and firmware for the hardware
accelerator described in `docs/02-bonsai-accelerator-hardware-blueprint.pdf`.
The upstream NEORV32 submodule remains unchanged.

The reproducible Tang Nano 9K Gowin projects and their synthesis results are
documented in `gowin/README.md`.

The current implementation establishes the CFS identity, interface version,
shared register map, service and transfer identifiers, semantic tile roles,
command lifecycle, and per-command counters. The attention service contract
adds query-head, KV-head, head-dimension, context-length, and append-position
configuration, with signed-16 vectors split into indexed 32-element tiles.
The attention/KV engine follows append-first ordering, maps query heads to
grouped-query KV heads, returns current K/V as append-writeback tiles, and
traverses historical K and V tiles. Its score phase retains the active query and
current K vectors, computes scaled signed-16 QK dot products, and stores one
signed Q16.16 score per context position. Stable normalization finds the maximum
score, evaluates a bounded fixed-point exponential, accumulates the denominator,
and retains Q0.16 weights. The V phase multiplies those weights by historical or
locally retained current-V elements, accumulates signed results, and emits
rounded, saturated signed-16 attention vectors. Proposal A now has a board-sized
transport contract for Q1_0 by Q8_0 rows. The matvec engine streams configured
rows of 128-element groups, reduces 32 sign-controlled Q8 lanes per block,
applies the Q1 and Q8 scales in separate pipeline stages, preserves a 64-bit
accumulator across groups, and emits one saturated signed 16-bit result per
row. It accepts raw FP16 scales for GGUF rows and signed fixed-Q8 scales for the
Tier 3 synthetic board fixture. `CPU_PUSH` deliberately resends the Q8 vector
for every row; activation reuse remains outside the current Proposal A profile.
The `CPU_PUSH` frontend provides independent ingress and egress FIFOs, request
metadata, backpressure, physical-byte counters, and frontend wait counters.
Local tile buffers stage complete role-tagged input and output transactions
between the FIFOs and engine. The Proposal B `MEM_STREAM` frontend uses
role-indexed descriptors and a burst adapter to transfer those same tiles
through the PSRAM-controller interface.

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
payloads, acknowledges repeated commands, checks both attention compatibility
shapes, their role-tagged tile sequences, GQA mapping, complete attention output
vectors, invalid-shape rejection, and the disabled-`MEM_STREAM` error behavior.
The two-word FIFOs exercise CPU-side backpressure, while local tiles keep the
engines independent of CPU drain timing.

## Check Proposal A synthesis

```sh
cd src/neorv32_bonsai_accelerator
./sim/check-q1-synth.sh
```

## Evaluate Proposal A

The dedicated firmware under `sw/q1_matvec_evaluation/` uses the Tier 3 board
and Bonsai compatibility inputs and emits command, engine, wait, traffic, work,
and checksum fields. Run both profiles from the repository root with:

```sh
python3 src/neorv32_bonsai_accelerator/evaluate-q1-matvec.py
```

The evaluation compares complete `CPU_PUSH` command cycles and engine-active
cycles with the corresponding Tier 3 software cycles. Logs and summaries are
written under `results/proposal_a_evaluation/q1_matvec/`.

The compatibility evaluation produced:

| Profile | Tier 3 software | `CPU_PUSH` command | Engine active | Command speedup | Active-cycle speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| Board, 1 x 128 | 7,934 | 1,804 | 82 | 4.398x | 96.756x |
| Bonsai, 1 x 2048 | 195,602 | 27,863 | 1,297 | 7.020x | 150.811x |

Both outputs match their Tier 3 checksums. `CPU_PUSH` prepares the packed
payload before command launch, validates each requested tile once, and writes
the complete tile through a tight MMIO burst. This keeps the full service 4.4x
to 7.0x faster than Tier 3 software without depending on `MEM_STREAM`.
`MEM_STREAM` remains a separate memory-path optimization, primarily for the
attention/KV proposal and later sustained-workload evaluation.

## Evaluate Proposal B CPU push

The dedicated firmware under `sw/attention_kv_evaluation/` uses the Tier 3
board and GQA compatibility fixtures. It prepares all payloads before launch,
services each requested tile with a tight MMIO burst, validates append
writeback and final signed-16 output vectors, and reports hardware-owned cycles,
waits, traffic, work and transaction counts. Run both profiles from the
repository root with:

```sh
python3 src/neorv32_bonsai_accelerator/evaluate-attention-kv-cpu-push.py
```

Logs and summaries are written under
`results/proposal_b_evaluation/attention_kv/cpu_push/`. The compatibility
evaluation produced:

| Profile | Tier 3 software | `CPU_PUSH` command | Engine active | Command speedup | Active-cycle speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| Board, H1/KVH1/D32/C2 | 489,007 | 5,453 | 398 | 89.677x | 1,228.661x |
| Bonsai GQA, H2/KVH1/D16/C2 | 494,741 | 4,874 | 412 | 101.506x | 1,200.828x |

Both outputs match the Tier 3 checksums, 5,274 and 7,569. The compute engine is
therefore complete under `CPU_PUSH`, but utilization remains 8.707% for board
and 9.383% for GQA because the engine spends most elapsed cycles waiting for
CPU-provided input. These results establish the straightforward hardware
baseline used to evaluate the descriptor-driven `MEM_STREAM` path.

## Evaluate Proposal B MEM_STREAM

`MEM_STREAM` uses role-indexed descriptors to move Q/K/V and output tiles
between backing memory and the same attention engine. The simulation memory
aperture is loaded before command timing. Timed transfers use a behavioral
model of the Gowin PSRAM HS controller's user-side interface configured for the
Tang Nano 9K: physical DQ16, 64-bit user beats, 32-byte bursts, a fixed-latency
setting of six, and an 18-user-clock minimum command interval. The controller
user clock shares the 27 MHz system-clock domain, corresponding to a 54 MHz
memory clock at the IP's 1:2 ratio. Initialization gates requests before fixture
execution; physical pins and electrical timing remain outside this
controller-level simulation.

```sh
python3 src/neorv32_bonsai_accelerator/evaluate-attention-kv-mem-stream.py
```

Results are written under
`results/proposal_b_evaluation/attention_kv/mem_stream/` and include direct
command-cycle and frontend-wait comparisons with CPU push. The evaluation
produced:

| Profile | Tier 3 software | `CPU_PUSH` command | `MEM_STREAM` command | vs. Tier 3 | vs. `CPU_PUSH` |
| --- | ---: | ---: | ---: | ---: | ---: |
| Board, H1/KVH1/D32/C2 | 489,007 | 5,453 | 810 | 603.712x | 6.732x |
| Bonsai GQA, H2/KVH1/D16/C2 | 494,741 | 4,874 | 706 | 700.766x | 6.904x |

Both outputs match the CPU-push and Tier 3 checksums. Engine utilization rises
from 8.707% to 51.756% for the board fixture and from 9.383% to 59.624% for the
GQA fixture because descriptor-driven bursts remove most CPU delivery waits.
These simulation results use the same controller contract as the dedicated
MEM_STREAM synthesis profile. Gowin maps that profile to 11,578 logic elements
against 8,640 available, so it cannot be placed on the Tang Nano 9K in its
current form; the complete CPU-push attention profile does fit and route.
