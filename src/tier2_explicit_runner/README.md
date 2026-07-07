# Tier 2: Explicit Bonsai C++ Runner

This directory contains a portable C++ runner used for Tier 2 `bonsai-explicit-runner.cpp`.

Internally, the file records the `llama.cpp`/GGML source files used as references and keeps the runner organized around explicit backend boundaries for Q1_0 matrix-vector work, attention, and the LM head, which is the purpose of this runner.

Build from the repository root:

```sh
c++ -std=c++17 -O3 -Wall -Wextra -Wpedantic \
  src/tier2_explicit_runner/bonsai-explicit-runner.cpp \
  -o /tmp/bonsai-explicit-runner
```

The default model path is shared with Tier 1:

```text
models/bonsai-1.7b-gguf/Bonsai-1.7B-Q1_0.gguf
```

If the GGUF is not present yet, run the Tier 1 setup first:

```sh
src/tier1_llama_cpp_benchmark/setup.sh
```

That script downloads `Bonsai-1.7B-Q1_0.gguf` from
[`prism-ml/Bonsai-1.7B-gguf`](https://huggingface.co/prism-ml/Bonsai-1.7B-gguf)
or links an existing local copy when `MODEL_SOURCE=/path/to/Bonsai-1.7B-Q1_0.gguf`
is provided.

Current flags:

- `--model path`: set the Bonsai GGUF path.
- `--tokens id[,id...]`: provide explicit token ids for trace runs.
- `--top-k n`: choose how many top logits to print for each decoded token.
- `--inspect-model`: inspect the Bonsai GGUF metadata and tensor map.
- `--check-q1`: run Q1_0 layout/dequantization/matvec validation checks.
- `--trace-one-token`: run explicit decode over the provided token ids and print generated-token/top-k output.

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

Token-generation trace:

```sh
/tmp/bonsai-explicit-runner \
  --model models/bonsai-1.7b-gguf/Bonsai-1.7B-Q1_0.gguf \
  --trace-one-token \
  --top-k 10 \
  --tokens 151643,25
```

The trace keeps a KV cache across the listed token ids, then prints `generated_token` and `top_token` rows from the LM-head logits for each decode step. 

llama.cpp parity checks:

```sh
cmake --build external/llama.cpp/build-cpu \
  --target llama-debug \
  --config Release \
  -j 6
```

```sh
python3 src/tier2_explicit_runner/check_llama_cpp_parity.py \
  --policy exact \
  '!' '!!' 'Hello' 'The' ' quick' ' brown' ' fox' '1'
```

```sh
python3 src/tier2_explicit_runner/check_llama_cpp_parity.py \
  --policy top-k-overlap \
  --top-k 10 \
  --min-overlap 4 \
  --verbose \
  'Hello world' 'The quick' 'The quick brown' 'The quick brown fox' '1 2 3'
```

These show close agreement for some short prompts and visible drift as the context grows, which is acceptable due to the project's focus on the Q1_0 bottleneck and not on exact single-file parity with llama.cpp.