# Tier 1: llama.cpp CPU Benchmark

This folder contains the Tier 1 CPU baseline experiment for Bonsai/Q1_0 inference. The baseline is CPU-based because the course board does not provide a GPU path, and because CPU-only local inference is still a relevant target for small low-bit models. Public Bonsai/PrismML material describes the smaller 1-bit models as having very small memory footprints, including a [1.7B model around 0.25 GB](https://huggingface.co/prism-ml/Bonsai-1.7B-gguf) and a [4B model around 0.57 GB](https://huggingface.co/prism-ml/Bonsai-4B-gguf), making them closer to edge/local-device deployment than ordinary 16-bit models. These are production-ready general-purpose small models, [slightly trailing behind SOTA scores for their parameter count but about an order of magnitude less memory footprint](https://github.com/PrismML-Eng/Bonsai-demo/blob/main/1-bit-bonsai-8b-whitepaper.pdf), and not just research toy implementations. And, as the announcement notes suggest, their inference has still a lot of [room for optimization and hardware co-design](https://prismml.com/news/bonsai-8b#:~:text=1%2Dbit%20Hardware%E2%80%8D) given the nature of binary operations instead of floating-point operations.

The benchmark starts from the original inference path. We use upstream `llama.cpp` as an external dependency, since running Bonsai/Q1_0 needs the full GGUF loader, tokenizer, runtime, model support, and GGML CPU/BLAS backends. The profiling patch is pinned to a specific upstream `llama.cpp` commit, for future reproducibility:

```text
1ec7ba0c14f33f17e980daeeda5f35b225d41994
```

`batched-bench.cpp` is the upstream benchmark entrypoint used for the tok/s baseline. `q1-profile.patch` adds operation-level profiling in `ggml-cpu` and `ggml-blas`, so the full benchmark can estimate how much prefill and decode time goes into Q1_0 matrix operations, attention/KV-cache work, and other runtime work.

## Commands

Set up the pinned and patched `llama.cpp` build:

```sh
src/tier1_llama_cpp_benchmark/setup.sh
```

This also prepares the default model path used below. Because the GGUF is too
large to keep in this repo, setup downloads
`Bonsai-1.7B-Q1_0.gguf` from
[`prism-ml/Bonsai-1.7B-gguf`](https://huggingface.co/prism-ml/Bonsai-1.7B-gguf)
on Hugging Face. If the model already lives elsewhere, pass it explicitly:

```sh
MODEL_SOURCE=/path/to/Bonsai-1.7B-Q1_0.gguf src/tier1_llama_cpp_benchmark/setup.sh
```

Run text generation:

```sh
src/tier1_llama_cpp_benchmark/run-single-inference.sh
```

The prompt and max completion length can be specified directly:

```sh
src/tier1_llama_cpp_benchmark/run-single-inference.sh \
  "Why are 1-bit LLMs interesting for CPU-only edge inference?" \
  384
```

Run one profiled prompt-based generation:

```sh
src/tier1_llama_cpp_benchmark/run-measured-inference.sh
```

This writes the model answer plus CPU/BLAS operation profile to `results/tier1_llama_cpp_benchmark/single/measured-inference.log`.

Run the full prefill/decode context sweep and write CSV summaries:

```sh
src/tier1_llama_cpp_benchmark/run-full-benchmark.py
```

By default this sweeps prompt lengths 0, 128, 512, 2048, 4096, 8192, 16384,
32768 with a 128-token decode run for each context length. The longer decode
run makes the profiled decode delta less sensitive to prefill-subtraction noise.
The context window defaults to 33024 so the 32768-token prompt still has room
for decode tokens when a shorter 32-token max-context run is used.

Default paths:

```sh
MODEL=models/bonsai-1.7b-gguf/Bonsai-1.7B-Q1_0.gguf
external/llama.cpp/build-cpu/bin/llama-cli
external/llama.cpp/build-cpu/bin/llama-batched-bench
```

Full benchmark outputs are written under:

```text
results/tier1_llama_cpp_benchmark/full/
```
