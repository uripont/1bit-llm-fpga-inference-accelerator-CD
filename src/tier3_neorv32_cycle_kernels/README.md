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
