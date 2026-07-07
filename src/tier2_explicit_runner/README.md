# Tier 2: Explicit Bonsai C++ Runner

This directory contains a portable C++ runner used for Tier 2 `bonsai-explicit-runner.cpp`.

Internally, the file records the `llama.cpp`/GGML source files used as references and keeps the runner organized around explicit backend boundaries for Q1_0 matrix-vector work, attention, and the LM head, which is the purpose of this runner.

Build from the repository root:

```sh
c++ -std=c++17 -O3 -Wall -Wextra -Wpedantic \
  src/tier2_explicit_runner/bonsai-explicit-runner.cpp \
  -o /tmp/bonsai-explicit-runner
```

Current flags:

- `--model path`: set the Bonsai GGUF path.
- `--tokens id[,id...]`: provide explicit token ids for trace runs.
- `--inspect-model`: inspect the Bonsai GGUF metadata and tensor map.
- `--check-q1`: run Q1_0 layout/dequantization/matvec validation checks.
- `--trace-one-token`: run the explicit one-token inference trace.

Run the runner:

```sh
/tmp/bonsai-explicit-runner
```

Inspect-model:

```sh
/tmp/bonsai-explicit-runner \
  --model models/bonsai-1.7b-gguf/Bonsai-1.7B-Q1_0.gguf \
  --inspect-model
```

Q1_0 check:

```sh
/tmp/bonsai-explicit-runner --check-q1
```

One-token trace:

```sh
/tmp/bonsai-explicit-runner \
  --model models/bonsai-1.7b-gguf/Bonsai-1.7B-Q1_0.gguf \
  --trace-one-token \
  --tokens 151643,25
```
