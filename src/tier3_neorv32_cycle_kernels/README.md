# Tier 3: NEORV32 Cycle Kernels

Tier 3 is the cycle-count baseline for the accelerator targets, reducing the target computations to small NEORV32 programs that can be measured in simulation.

The goal is to collect precise pre-acceleration metrics for the same two engines that will later be replaced by custom accelerator calls:

- `q1_matvec.c`: packed Q1_0 matrix-vector work.
- `attention_scan.c`: KV-cache attention score/value scan work.
- `reduced_bonsai.c`: a tiny 1-2 layer decode-style composition that calls the same Q1 and attention kernels.

The kernels should use GGUF-derived Bonsai tensors and the same target dimensions as the real model, but run only a reduced depth such as one or two layers. That keeps NEORV32 simulation practical while preserving the loop shapes that the accelerator engines need to replace.
