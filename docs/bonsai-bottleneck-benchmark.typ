#set page(
  paper: "a4",
  margin: (x: 2.0cm, y: 1.8cm),
)
#set text(
  font: "New Computer Modern",
  size: 10.2pt,
)
#set par(justify: true, leading: 0.56em)

#align(center)[
  #text(size: 17pt, weight: "bold")[Bonsai Benchmark Methodology and Bottlenecks Found]

  #v(0.35em)
  #text(size: 10pt)[Initial benchmark report - Oriol Pont, June 2026]
]

#v(0.7em)

= Starting point

As described in the root README, the project began with Bonsai-family 1-bit language models as the acceleration target. Bonsai-1.7B is attractive because it is a general-purpose compact LLM, not just a toy benchmark or architectural demo, and its Q1_0 weights expose a hardware-relevant computation pattern: packed one-bit signs, per-group scales, and many repeated fixed-weight linear layers.

After several early experiments, the benchmark is organized in _tiers_ according to the level of hardware abstraction and source code used. The first tier uses upstream `llama.cpp` as the known-correct software reference, because it provides the full Bonsai GGUF loading path, tokenizer/runtime support, and a practical CPU baseline for edge-style deployment. This tier answers where Bonsai spends time during real inference by instrumenting the `llama.cpp`/GGML CPU path and grouping profiled operator time into Q1_0 matrix operations, attention/KV-cache work, and other runtime work across increasing prompt lengths.

The second tier uses a self-contained explicit C++ runner for the same Bonsai GGUF model. Unlike `llama.cpp`, this runner is written as readable inference code with clear backend functions. It is used to extract full-model call counts and operation shapes that can later be mapped onto hardware experiments.

The third tier, developed after the software profiling, uses small NEORV32 simulation kernels to measure cycle counts for the specific hardware targets identified by the first two tiers. Together, the tiers separate three questions: where the real model spends time when run on CPU (to identify bottlenecks), how often each backend structure appears in the full model, and how many RISC-V/FPGA cycles a naive (reduced) implementation of each target costs.

#let prefill_rows = (
  (pp: 128,   tok_s: 244.448, q1: 88.24, attn: 4.90,  other: 6.87, verdict: [strong Q1]),
  (pp: 512,   tok_s: 407.925, q1: 81.75, attn: 12.70, other: 5.55, verdict: [strong Q1]),
  (pp: 2048,  tok_s: 343.691, q1: 63.96, attn: 31.74, other: 4.30, verdict: [mixed]),
  (pp: 4096,  tok_s: 269.219, q1: 49.86, attn: 46.93, other: 3.21, verdict: [mixed]),
  (pp: 8192,  tok_s: 155.640, q1: 31.33, attn: 63.11, other: 5.56, verdict: [attention]),
  (pp: 16384, tok_s: 108.622, q1: 20.12, attn: 78.16, other: 1.72, verdict: [attention]),
  (pp: 32768, tok_s: 56.104,  q1: 10.70, attn: 88.01, other: 1.29,  verdict: [attention]),
)

#let decode_rows = (
  (pp: 0,     tok_s: 63.277, q1: 93.03, attn: 2.80,  other: 4.17),
  (pp: 128,   tok_s: 63.203, q1: 90.66, attn: 6.49,  other: 2.85),
  (pp: 512,   tok_s: 48.046, q1: 75.61, attn: 15.51, other: 8.87),
  (pp: 2048,  tok_s: 35.141, q1: 54.94, attn: 42.44, other: 2.61),
  (pp: 4096,  tok_s: 14.159, q1: 37.50, attn: 50.48, other: 12.02),
  (pp: 8192,  tok_s: 11.274, q1: 34.79, attn: 64.87, other: 0.34),
  (pp: 16384, tok_s: 5.428,  q1: 12.30, attn: 82.87, other: 4.83),
  (pp: 32768, tok_s: 0.022,  q1: 3.40,  attn: 94.74, other: 1.86),
)

#let fmt(x) = {
  let scaled = calc.round(x * 100)
  let whole = calc.floor(scaled / 100)
  let fraction = calc.rem(scaled, 100)
  str(whole) + "." + if fraction < 10 { "0" + str(fraction) } else { str(fraction) }
}
#let dominant-cell(value, row) = if value >= row.q1 and value >= row.attn and value >= row.other {
  strong(fmt(value))
} else {
  fmt(value)
}

#let bottleneck-table(title, rows) = {
  text(weight: "bold")[#title]
  table(
    columns: (0.7fr, 0.9fr, 0.85fr, 0.85fr, 0.85fr),
    stroke: (x, y) => if y == 0 { (bottom: 0.8pt) } else { none },
    inset: (x: 4pt, y: 3pt),
    align: (left, right, right, right, right),
    table.header([Prompt], [Tok/s], [Q1_0 %], [Attn. %], [Other %]),
    ..rows.map(row => (
      [#str(row.pp)],
      [#fmt(row.tok_s)],
      [#dominant-cell(row.q1, row)],
      [#dominant-cell(row.attn, row)],
      [#dominant-cell(row.other, row)],
    )).flatten(),
  )
}

= Tier 1: llama.cpp CPU profiling

The first tier is the full software baseline, running Bonsai-1.7B Q1_0 GGUF through the upstream `llama.cpp` execution path, and profiling where time is spent inside the CPU operator graph. This is the reference used to decide which parts of inference are worth turning into hardware targets.

== Benchmark setup

#list(
  [Model: `Bonsai-1.7B-Q1_0.gguf`.],
  [Runtime: patched `llama.cpp`, using the `llama-batched-bench` benchmark executable, built from `batched-bench.cpp`.],
  [Machine: MacBookPro with Apple M1 Pro.],
  [Backend: CPU-only `llama.cpp` build with Metal/GPU disabled, Accelerate/BLAS enabled.],
  [Threading: 6 benchmark threads for prompt and decode runs.],
)

The result files for these tables are, using "pp" prompts processed, and "tg" tokens generated:

#list(
  [`results/tier1_llama_cpp_benchmark/full/prefill-summary.csv`],
  [`results/tier1_llama_cpp_benchmark/full/decode-summary.csv`],
  [`results/tier1_llama_cpp_benchmark/full/pl_1_pp_32768_tg_32.log`, as an example output for a specific run], 
)

The percentages in this tier are shares of profiled operator time. Prefill rows measure prompt processing, while decode rows measure autoregressive token generation as the KV cache grows. The profiling patch accumulates elapsed time inside GGML CPU/BLAS operators, and the summary scripts group that time into three buckets:

#list(
  [`Q1_0`: time in `MUL_MAT` operations where the source weight tensor is Q1_0.],
  [`Attention`: time in `FLASH_ATTN_EXT`, used as the profiling proxy for attention and KV-cache traffic.],
  [`Other`: remaining profiled operator time.],
)

The full sweep can be reproduced with `src/tier1_llama_cpp_benchmark/run-full-benchmark.py` after the `llama.cpp` setup step. The commands and setup details are documented in `src/tier1_llama_cpp_benchmark/README.md`.

#pagebreak()

== Benchmark results

#v(0.25em)

#bottleneck-table([Prefill summary], prefill_rows)

Short and medium prompt prefill is dominated by Q1_0 matrix work. At 128 and 512 prompt tokens, Q1_0 operations account for more than 80% of profiled operator time. As the prompt grows, attention/KV-cache work rises steadily, and by 8192 tokens and above attention becomes the dominant prefill cost.

#v(0.85em)

#bottleneck-table([Decode summary], decode_rows)

Early decode is also Q1_0-heavy, because each new token applies the fixed model weights while the KV history is still short. Long-context decode shifts toward attention/KV-cache traversal.

== Tier 1 conclusions: a dual-target approach

The measured split identifies two clear, different regimes. At short contexts, where the model repeatedly applies fixed Q1_0 weights and attention has little history to read, the dependence is primarily arithmetic and packed weight processing: extracting one-bit signs, applying group scales, accumulating dot products, and writing output activations across many layers. On the other hand, at long contexts, attention becomes dominant. This dependence is mainly memory traffic and data movement: the KV cache grows with sequence length, and each generated token must access a larger history.

Since we aim to increase throughput at all different context sizes, this first benchmark already suggests embracing a dual-target approach. Before assessing the SoC restrictions and architecture, the project should treat these as separate bottlenecks with different causes: one mostly arithmetic over packed weights, the other mostly memory bandwidth and cache traversal.

= Tier 2: self-contained Bonsai C++ runner

Tier 1 is the best reference for real CPU runtime behavior and understanding which were the main bottlenecks. For hardware co-design, a more direct source view is useful because the relevant work in `llama.cpp` is spread through the runtime, GGML graph execution, tensor abstractions, backend dispatch, tokenizer/runtime setup, and optimized kernels, which is complex and time-consuming. The project therefore also needs a simpler program, more adequate to the scope of the course project, that still runs the real Bonsai tensors and exposes the inference path as explicit loops and named backend functions.

The Tier 2 runner is kept under `src/tier2_explicit_runner/`. The main source file is `src/tier2_explicit_runner/bonsai-explicit-runner.cpp`, and the build/run commands are documented in `src/tier2_explicit_runner/README.md`. This tier is used to inspect the GGUF tensors and extract explicit operation metrics from a self-contained C++ Bonsai forward (decode) pass, including Q1_0 matrix-vector call counts, rows, dot-product elements, groups of 128 packed weights, attention calls,...

#pagebreak()

