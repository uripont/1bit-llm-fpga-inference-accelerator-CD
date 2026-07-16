# Tier 3: NEORV32 Cycle Baselines

Tier 3 measures the two pre-acceleration software services on a simulated NEORV32 CPU. These programs define the operation shapes, inputs, outputs, checksums, and cycle boundaries later used by the hardware evaluations.

- `q1_matvec.c`: packed Q1_0 by Q8_0 matrix-vector work.
- `attention_scan.c`: K/V append, QK scoring, stable softmax, weighted-V accumulation, and attention output.

## Q1 Matvec Contract

The activation is already quantized into Q8_0 blocks and the weights already use the GGUF Q1_0 block layout. The timed service reads packed blocks, performs sign-controlled integer accumulation, applies both quantization scales, and writes signed-16 row outputs.

Two profiles are retained:
- `board`: one synthetic 128-element Q1/Q8 group within the 16 KiB IMEM and 8 KiB DMEM simulation configuration used for the board SoC.
- `bonsai`: one 2,048-element row using packed GGUF data and enlarged simulated memories. Fixture provenance is documented in `generated/README.md`.

With the development container running, execute the benchmark drivers from a host terminal at the repository root. The `devcontainer` runner enters the container with `docker exec`.

```sh
python3 src/tier3_neorv32_cycle_kernels/run-q1-matvec-benchmark.py --runner devcontainer --profile board --variants q1_group_1row
python3 src/tier3_neorv32_cycle_kernels/run-q1-matvec-benchmark.py --runner devcontainer --profile bonsai --variants q1_hidden_1row
```

## Attention/KV Contract

Q, K, and V are available at the attention backend boundary. The timed service appends current K/V, maps query heads to KV heads, scans K for scaled QK scores, applies stable softmax, scans V for the weighted output, and writes signed-16 attention vectors. The board and GQA fixtures use deterministic synthetic Q/K/V data because Tier 3 targets the backend operation contract rather than a full layer trace.

Service and phase cycles include the ordinary CPU loads and stores used by the software implementation. They provide the complete pre-acceleration cost; hardware counters later separate useful engine activity from frontend and buffer waiting.

```sh
python3 src/tier3_neorv32_cycle_kernels/run-attention-kv-benchmark.py --runner devcontainer --profile board
python3 src/tier3_neorv32_cycle_kernels/run-attention-kv-benchmark.py --runner devcontainer --profile bonsai
```

Committed build logs, simulation logs, and CSV summaries live under `results/tier3_neorv32_cycle_kernels/`.
