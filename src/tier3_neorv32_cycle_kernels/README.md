# Tier 3: NEORV32 Cycle Kernels

Tier 3 is the cycle-count baseline for the accelerator targets, reducing the target computations to small NEORV32 programs that can be measured in simulation.

The goal is to collect precise pre-acceleration metrics for the same two engines that will later be replaced by custom accelerator calls:

- `q1_matvec.c`: packed Q1_0 matrix-vector work.
- `attention_scan.c`: KV-cache attention score/value scan work.

The kernels should use GGUF-derived Bonsai tensors and the same target dimensions as the real model, but run only a reduced depth such as one or two layers. That keeps NEORV32 simulation practical while preserving the loop shapes that the accelerator engines need to replace.

## Q1 matvec baseline contract

`q1_matvec.c` is the pre-acceleration software baseline for the future Q1_0 matvec accelerator.

- input activation data is already in Q8_0 blocks,
- Q1_0 weights are already packed as scale bytes plus 128 sign bits,
- the timed kernel reads those packed blocks, performs sign-controlled add/sub accumulation, applies scales, and writes/checks output rows.

The runner exposes two profiles:

- `board`: Tang Nano 9K-style NEORV32 memory envelope, synthetic packed Q1/Q8 tiles, currently intended for board-faithful pre/post acceleration comparison.
- `bonsai`: Bonsai operation-shape profile, GGUF fixture-backed packed Q1 rows, enlarged simulation memory for model-shape extrapolation.

Run the baselines:

```bash
python3 src/tier3_neorv32_cycle_kernels/run-q1-matvec-benchmark.py --runner devcontainer --profile board --variants q1_group_1row

python3 src/tier3_neorv32_cycle_kernels/run-q1-matvec-benchmark.py --runner devcontainer --profile bonsai --variants q1_hidden_1row
```

## Attention/KV pre-acc baseline contract

`attention_scan.c` is the software pre-acceleration reference for the future attention/KV engine.

- Q, K, and V are already available at the attention backend boundary,
- the timed service appends current K/V, scans K for QK scores, applies exact softmax, scans V, and writes the attention output,
- reported phase cycles are software phase cycles, not hardware memory-wait counters.

This benchmark defines the operation shape and CPU software *cost, mostly compute-wise* (cycle count as the main proxy). Later accelerator simulations should compare how it performs to the same operation shape with hardware acceleration, as well as how such accelerated computations perform when usingnaive hardware memory access against hardware-backed, optimized streaming/FIFO memory access.

Run the baselines:

```bash
python3 src/tier3_neorv32_cycle_kernels/run-attention-kv-benchmark.py --runner devcontainer --profile board

python3 src/tier3_neorv32_cycle_kernels/run-attention-kv-benchmark.py --runner devcontainer --profile bonsai
```
