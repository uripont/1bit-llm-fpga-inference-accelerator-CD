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
  #text(size: 17pt, weight: "bold")[Bonsai Accelerator Hardware Blueprint]

  #v(0.35em)
  #text(size: 10pt)[Architecture proposal before implementation - Oriol Pont, July 2026]
]

#v(0.7em)

#let block(body, fill: rgb("f8fafc")) = box(
  inset: 5pt,
  radius: 2pt,
  stroke: 0.6pt + rgb("475569"),
  fill: fill,
  body,
)

#let control-fill = rgb("eef2ff")
#let compute-fill = rgb("ecfdf5")
#let stream-fill = rgb("fff7ed")

#let arrow = text(size: 13pt)[->]
#let biarrow = text(size: 13pt)[<=>]

#let sig-table(rows) = table(
  columns: (1.65fr, 0.55fr, 2.25fr),
  stroke: (x, y) => if y == 0 { (bottom: 0.8pt) } else { none },
  inset: (x: 4pt, y: 3pt),
  table.header([Signal group], [Dir.], [Purpose]),
  ..rows,
)

#let fsm-table(rows) = table(
  columns: (0.95fr, 2.3fr, 1.6fr),
  stroke: (x, y) => if y == 0 { (bottom: 0.8pt) } else { none },
  inset: (x: 4pt, y: 3pt),
  table.header([State], [Action], [Next condition]),
  ..rows,
)

= Scope and Benchmark Basis

This document is the pre-implementation hardware blueprint for the Bonsai accelerator. It describes the architecture, submodules, signal groups, and control FSMs that guide development. It intentionally does not lock down low-level implementation constants such as FIFO depth, exact fixed-point formats, number of compute lanes, or final bus widths, since those should be selected during RTL implementation and synthesis.

The software target is Bonsai-1.7B Q1_0, a compact LLM, as previously discussed. The model image is around 242 MB. Since the course board is a Sipeed Tang Nano 9K with a Gowin LittleBee GW1NR-9 FPGA running a NEORV32 System-on-Chip (SoC), it is far too restricted to hold the full model image.

The three-tier benchmark exploration previously done has allowed defining the scope. To recap, Tier 1 uses `llama.cpp` as the full software reference and shows two important runtime regimes: short-context inference is dominated by Q1_0 matrix operations, while long-context inference shifts toward attention and KV-cache work. Tier 2 exposes the same Bonsai path in a simpler, custom, self-contained C++ runner, which allows measurement of the repeated Q1_0 matrix-vector calls over 128-weight packed groups, plus per-layer attention over growing KV history. Tier 3 then gives reduced cycle-level kernels for the same targets, which can be implemented and measured on the NEORV32 SoC, and that we want to accelerate.

Since Tier 2 is a CPU/software path, it can in principle run on a NEORV32 SoC if enough memory, storage, and simulation time are available. The exact Tier 2 C++/GGUF runner code is host-oriented, but the SoC-facing portable CPU path preserves the same backend boundaries. The fine-grained on-device measurements are restricted to Tier 3 kernels, keeping Tier 2 as the full-model accounting layer used for extrapolation.

The final architecture therefore contains two proposals, each of which addresses one of the two bottlenecks identified:

#enum[
  *Proposal A: compute-first tensor accelerator.* accelerate the Q1_0 fixed-weight matrix-vector backend used by Bonsai linear layers.
][
  *Proposal B: stream and memory-management improvement.* reduce CPU communication overhead and long-context attention/KV traversal cost with FIFO/stream handshaking and latency hiding, among other possible techniques.
]

= Common Top-Level Architecture

In the proposed architecture, the accelerator is a co-processor to the NEORV32 CPU inside the SoC. The CPU is the system controller, running the Bonsai-like harness that orchestrates model execution and launches accelerator work when reaching the target workloads. As discussed, the *accelerator focuses on providing the demonstration of two services*: a Q1_0 tensor service and a stream-based attention/KV service.

#figure(
  align(center)[
    #grid(
      columns: (1.0fr, auto, 1.15fr, auto, 1.15fr, auto, 1.35fr),
      align: center + horizon,
      block([*NEORV32 CPU*\
      driver\
      benchmark\
      runtime control], fill: control-fill),
      arrow,
      grid(
        columns: (1fr,),
        row-gutter: 0.35em,
        block([*CFS register interface*\
        control/status\
        mode/config\
        descriptors], fill: control-fill),
        block([*FIFO / stream front end*\
        input burst\
        valid/ready\
        output drain], fill: stream-fill),
      ),
      arrow,
      grid(
        columns: (1fr,),
        row-gutter: 0.35em,
        block([*Accelerator top*\
        command FSM\
        engine select\
        counters], fill: control-fill),
        block([*Local buffer bank*\
        x / weights\
        Q/K/V\
        output], fill: stream-fill),
      ),
      arrow,
      grid(
        columns: (1fr,),
        row-gutter: 0.35em,
        block([*Q1_0 matvec engine*\
        packed signs\
        group scales\
        reductions], fill: compute-fill),
        block([*Attention/KV stream engine*\
        KV traversal\
        QK scores\
        weighted V output], fill: stream-fill),
      ),
    )
  ],
  caption: [Common architecture used by both proposals. The upper lane is the CFS control path: the CPU configures `accelerator_top`, which runs the command FSM, selects the engine, and exposes counters/status. The lower lane is the data path: bulk payloads enter through the FIFO/stream front end, are staged in local buffers, and are consumed by either the Q1_0 matvec engine or the attention/KV stream engine.],
)
