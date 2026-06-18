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
  #text(size: 17pt, weight: "bold")[Bonsai CPU Baseline and Bottleneck Scope]

  #v(0.35em)
  #text(size: 10pt)[Initial benchmark report]
]

#v(0.7em)

= Starting point

As described in the root README, the project began with Bonsai-family 1-bit language models as the acceleration target. Bonsai-1.7B is attractive because it is a general-purpose compact LLM, not a toy benchmark or architectural demo, and its Q1_0 weights expose a specific computation pattern: packed one-bit signs, group scales, and many fixed-weight linear layers. The initial software reference is upstream `llama.cpp`, because it gives a practical CPU-based baseline for edge deployment, and a known-correct execution path for profiling it. The first question after this initial setup was determining where Bonsai actually spends time when running end-to-end inference, from both prefilling (prompt processing) and decoding (autoregressive token generation). To answer that, a benchmark was created to instrument the `llama.cpp`/GGML CPU path and profiled operator time into multiple buckets according to operation type. The benchmark is run across increasing prompt lengths to make the result capture both short and long-context behavior.

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

= Benchmark results

The result files for these tables are, using "pp" prompts processed, and "tg" tokens generated:

#list(
  [`results/baseline_benchmark/full/prefill-summary.csv`],
  [`results/baseline_benchmark/full/decode-summary.csv`],
  [`results/baseline_benchmark/full/pl_1_pp_32768_tg_32.log`, as an example output for a specific run], 
)

#v(0.25em)

#bottleneck-table([Prefill summary], prefill_rows)

#v(0.85em)

#bottleneck-table([Decode summary], decode_rows)


#text(size: 8.7pt)[Percentages are shares of profiled operator time. Q1_0 is `MUL_MAT` with Q1_0 source weights. Attention is `FLASH_ATTN_EXT`, which is the profiled proxy for attention and KV-cache traffic. Decode rows use 128 generated tokens except the 32768-token row, which uses the stored 32-token max-context run.]

== Bottleneck analysis

The measured split identifies two clear, different regimes. At short contexts, where the model repeatedly applies fixed Q1_0 weights and attention has little history to read. The dependence is primarily arithmetic and packed weight processing: extracting one-bit signs, applying group scales, accumulating dot products, and writing output activations across many layers. On the other hand, at long contexts, attention becomes dominant. This dependence is mainly memory traffic and data movement: the KV cache grows with sequence length, and each generated token must access a larger history.