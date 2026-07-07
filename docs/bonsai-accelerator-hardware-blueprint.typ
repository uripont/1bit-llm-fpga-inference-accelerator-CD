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
#let control-text = rgb("3730a3")
#let compute-text = rgb("047857")
#let stream-text = rgb("c2410c")

#let arrow = text(size: 13pt)[->]
#let biarrow = text(size: 13pt)[<=>]

#let fsm-table(rows) = table(
  columns: (0.9fr, 2.85fr, 1.0fr, 1.0fr),
  stroke: (x, y) => if y == 0 { (bottom: 0.8pt) } else { none },
  table.header([State], [Action / outputs], [Condition], [Next state]),
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

#pagebreak()

= Top-Level Modules and Signal Groups

This section defines the shared accelerator shell before specifying the two engines. The goal is to fix the module boundaries and control flow that both proposals need: CPU-visible control registers, optional FIFO/stream movement, local buffering, engine dispatch, status, and counters. The exact Q1_0 datapath and the exact attention/KV datapath are intentionally left as black-box services.

== Top-Level Submodules

#table(
  columns: (1.15fr, 2.65fr, 1.5fr),
  stroke: (x, y) => if y == 0 { (bottom: 0.75pt) } else { none },
  table.header([Submodule], [Responsibility], [Stored state]),
  [`cfs_reg_file`], [CPU-visible memory-mapped control/status interface. Holds the command descriptor, start/clear bits, mode selection, and readable status/counters.], [descriptor fields, status bits],
  [`stream_frontend`], [FIFO/stream data ingress and egress. Accepts burst payloads from the CPU-side interface and drains result words back to software.], [FIFO levels, route tags],
  [`local_buffer_bank`], [Shared staging memory between stream input and engines. Stores input vector tiles, packed weight groups, Q/K/V tiles, and output words.], [buffer valid bits, read/write pointers],
  [`accel_top`], [Main command controller. Reads the descriptor, checks resources, selects one engine, launches work, waits for completion, and publishes final status.], [mode, active engine, command state],
  [`q1_matvec_engine`], [Proposal A service endpoint. Consumes local-buffered vector/weight data and produces matrix-vector results.], [engine-local state],
  [`attn_kv_engine`], [Proposal B attention/KV service endpoint. Consumes Q/K/V data through the stream/local-buffer path and produces attention output.], [engine-local state],
  [`counter_block`], [Performance and debug counters shared by both proposals: total cycles, CPU-blocked cycles, FIFO stalls, engine-active cycles, and command completions.], [cycle and event counters],
)

The top-level shell therefore has two clear boundaries, similarly reflected in the previous diagram. On the CPU side, only `cfs_reg_file` and `stream_frontend` are visible. On the engine side, `accel_top` exposes a common launch/completion contract to either `q1_matvec_engine` or `attn_kv_engine`.

== Top-Level Signal Groups

#table(
  columns: (1.25fr, 1.5fr, 1.0fr, 1.7fr),
  stroke: (x, y) => if y == 0 { (bottom: 0.8pt) } else { none },
  table.header([Interface], [Direction], [Representative signals (TBD)], [Purpose]),
  [Clock/reset],
  [global in],
  [
    `clk` \
    `rst_n`
  ], table.cell(align: horizon)[Common clock and reset for all accelerator modules.],
  [CFS register bus],
  [#text(fill: control-text)[CPU] `<->` #text(fill: control-text)[CFS]],
  [
    `cfs_we` \
    `cfs_re` \
    `cfs_addr` \
    `cfs_wdata` \
    `cfs_rdata`
  ], table.cell(align: horizon)[Memory-mapped CFS access for control, status, descriptor, and counters. Exact address layout remains implementation-defined.],
  [Command descriptor],
  [#text(fill: control-text)[CFS] `->` #text(fill: control-text)[top]],
  [
    `cmd_start` \
    *`cmd_mode`* \
    `cmd_clear` \
    `cmd_error_clear` \
    `desc_valid` \
    `desc_shape` \
    `desc_payload_len` \
    `desc_result_len`
  ], table.cell(align: horizon)[Decoded command and descriptor. `cmd_mode` selects Q1_0 matvec, attention/KV, or a stream-only diagnostic mode. Width and packing remain implementation-defined.],
  [Status and counters],
  [#text(fill: control-text)[top/counters] `->` #text(fill: control-text)[CFS]],
  [
    `status_busy` \
    `status_done` \
    `status_error` \
    `status_engine` \
    `cnt_enable` \
    `cnt_event` \
    `cnt_snapshot`
  ], table.cell(align: horizon)[CPU-readable lifecycle status, active/finished engine identity, and performance event capture.],
  [Input stream],
  [#text(fill: control-text)[CPU] `->` #text(fill: stream-text)[stream]],
  [
    `in_valid` \
    `in_ready` \
    `in_data` \
    `in_last`
  ], table.cell(align: horizon)[Input payload stream used by the FIFO/stream front end, especially for Proposal B style transfer.],
  [Output stream],
  [#text(fill: stream-text)[stream] `->` #text(fill: control-text)[CPU]],
  [
    `out_valid` \
    `out_ready` \
    `out_data` \
    `out_last`
  ], table.cell(align: horizon)[Output stream for result words, checksums, or counter snapshots.],
  [Local buffer access],
  [#text(fill: stream-text)[stream/buffer] `<->` #text(fill: compute-text)[engine]],
  [
    `buf_wr_en` \
    `buf_wr_bank` \
    `buf_wr_data` \
    `buf_rd_en` \
    `buf_rd_bank` \
    `buf_rd_data`
  ], table.cell(align: horizon)[Read/write access to local staging banks shared by the stream front end and selected engine.],
  [Engine command],
  [#text(fill: control-text)[top] `<->` #text(fill: compute-text)[engine]],
  [
    `engine_start` \
    `engine_kind` \
    `engine_busy` \
    `engine_done` \
    `engine_error`
  ], table.cell(align: horizon)[Common launch/completion handshake. Only one engine is active for a command.],
  [Engine data],
  [#text(fill: compute-text)[engine] `<->` #text(fill: stream-text)[buffer]],
  [
    `engine_in_req` \
    `engine_in_valid` \
    `engine_out_valid` \
    `engine_out_ready`
  ], table.cell(align: horizon)[Generic data movement contract between selected engine and local buffers. Engine-specific meaning is defined later.],
)

With these, the high-level design of the accelerator is complete, without prematurely jumping into implementation details. The next section defines the control Finite-State Machines (FSMs) that orchestrate the top-level flow, the stream front end, and the local buffer bank, before moving to the two engines.

= Control Finite-State Machines
== `accel_top` Finite-State Machine

`accel_top` is the main top-level controller. It validates commands, coordinates buffers/streams, launches the selected engine, and reports completion.

#fsm-table((
  [`RESET`], [Clear status bits, selected engine, command registers, local control flags, and counter enables.], [reset released], [`IDLE`],
  [`IDLE`], [Keep `status_busy = 0`; wait for a new command with no uncleared result.], [`cmd_start && desc_valid` \
  otherwise], [`LATCH_DESC` \
  stay],
  [`LATCH_DESC`], [Copy `cmd_mode` and descriptor fields from `cfs_reg_file` into internal command registers.], [descriptor latched], [`CHECK_RESOURCES`],
  [`CHECK_RESOURCES`], [Validate selected mode, expected payload/result lengths, and availability of the stream/buffer path.], [valid \ or \
  invalid], [`PREPARE_INPUT` \ or \
  `ERROR`],
  [`PREPARE_INPUT`], [Set `status_busy = 1`; request input fill when streamed input is required, or mark input ready when data is already resident.], [input ready \ or \
  stream/buffer fault], [`START_ENGINE` \ or \
  `ERROR`],
  [`START_ENGINE`], [Assert `engine_start` with `engine_kind` selecting either `q1_matvec_engine` or `attn_kv_engine`.], [engine accepted \ or \
  illegal engine response], [`WAIT_ENGINE` \ or \
  `ERROR`],
  [`WAIT_ENGINE`], [Keep `status_busy = 1`; count active/stall events and wait for selected engine completion.], [`engine_done` \ or \
  `engine_error`], [`PUBLISH_RESULT` \ or \
  `ERROR`],
  [`PUBLISH_RESULT`], [Mark output buffer/FIFO as readable, snapshot counters, and prepare final status fields.], [result visible], [`DONE`],
  [`DONE`], [Set `status_done = 1`, clear `status_busy`, and hold result/status until software acknowledges.], [`cmd_clear` \
  new start before clear], [`IDLE` \
  stay],
  [`ERROR`], [Set `status_error = 1`, clear `status_busy`, latch error code, and block new commands.], [`cmd_error_clear` \
  otherwise], [`IDLE` \
  stay],
))

== `stream_frontend` FSM

#fsm-table((
  [`IDLE`], [Hold stream counters; keep `in_ready`/`out_valid` inactive unless a descriptor requests movement.], [input phase \ or \
  output phase \
  otherwise], [`ACCEPT_INPUT` \ or \
  `SERVE_OUTPUT` \
  stay],
  [`ACCEPT_INPUT`], [Assert `in_ready` when target space exists; accept `in_data` on `in_valid && in_ready`.], [word accepted \ or \
  no space \ or \
  length/packet fault], [`ROUTE_INPUT` \ or \
  `WAIT_SPACE` \ or \
  `STREAM_ERROR`],
  [`ROUTE_INPUT`], [Use descriptor context to route the accepted word into the selected local-buffer bank and increment payload count.], [more input expected \ or \
  payload complete \  or \
  buffer unavailable], [`ACCEPT_INPUT` \ \ or \
  `FLUSH` \ \ or \
  `WAIT_SPACE`],
  [`WAIT_SPACE`], [Un-assert `in_ready` while the target FIFO or local-buffer bank cannot accept another word.], [space available \ \ or \
  protocol fault], [`ACCEPT_INPUT` or `ROUTE_INPUT` \ or \
  `STREAM_ERROR`],
  [`SERVE_OUTPUT`], [Read result words from output buffer/FIFO and assert `out_valid` while data is available.], [`out_valid && out_ready`, more data \ or \
  last result word \ or \
  underflow], [stay \ \ \ or \
  `FLUSH` \ or \
  `STREAM_ERROR`],
  [`FLUSH`], [Close packet boundary, check `in_last`/`out_last`, and finalize payload/result counters.], [packet consistent \ or \
  length/last mismatch], [`STREAM_DONE` \ \ or \
  `STREAM_ERROR`],
  [`STREAM_DONE`], [Expose stream completion to `accel_top` and hold completion until acknowledged.], [top acknowledges], [`IDLE`],
  [`STREAM_ERROR`], [Latch overflow, underflow, unexpected `last`, or length mismatch and expose fault to `accel_top`.], [error cleared], [`IDLE`],
))

== `local_buffer_bank` Control FSM

The local buffers are a shared staging area, and specifically not a third accelerator. They decouple CPU/stream timing from engine timing and give both engines a common data source/sink.

#fsm-table((
  [`IDLE`], [No active ownership change, valid bits and pointers retain their current values.], [fill request \ or \
  engine read request \ or \
  clear request], [`FILL_BANK` \ or \
  `SERVE_ENGINE` \ \  or \
  `CLEAR_BANK`],
  [`FILL_BANK`], [Accept writes from `stream_frontend` into the selected bank and advance write pointer.], [bank filled/payload complete \ or \
  overflow/conflict], [`MARK_READY` \ \ or \
  `CLEAR_BANK` or error to top],
  [`MARK_READY`], [Set bank valid bit and expose input readiness to `accel_top` and the selected engine.], [read granted \ or \
  clear request], [`SERVE_ENGINE` \ or \
  `CLEAR_BANK`],
  [`SERVE_ENGINE`], [Grant read access to the selected engine and advance read pointer as the engine consumes data.], [engine releases input bank \ or \
  read conflict], [`CAPTURE_OUTPUT` or `IDLE` \ or \
  error to top],
  [`CAPTURE_OUTPUT`], [Accept result words from the selected engine into output bank/FIFO and advance output pointer.], [result complete \ or \
  output full], [`DRAIN_OUTPUT` \ or \
  stay or error to top],
  [`DRAIN_OUTPUT`], [Allow `stream_frontend` or CFS read path to drain result words from the output bank.], [result drained \ or \
  drain stalled], [`CLEAR_BANK` \ or \
  stay],
  [`CLEAR_BANK`], [Clear selected valid flags and reset bank pointers for the next command.], [clear complete], [`IDLE`],
))


== Counter Policy

In terms of counters, the CPU should be able to snapshot the following events for performance analysis:

#list(
  [`total_cycles`: cycles from accepted `cmd_start` to `DONE` or `ERROR`.],
  [`engine_active_cycles`: cycles where the selected engine is busy.],
  [`fifo_wait_cycles`: cycles where input or output transfer is blocked by valid/ready backpressure.],
  [`buffer_wait_cycles`: cycles where an engine waits for local-buffer data or output space.],
  [`cpu_blocked_cycles`: cycles measured for blocking software interaction, in Proposal B evaluation.],
)

This completes the top-level blueprint at the SoC level and its contract and control interface. Of course, this is to guide the design process, and can be refined as the design progresses. The next sections can specialize the two rightmost services separately: first the Q1_0 matvec engine for Proposal A, then the attention/KV stream engine and FIFO/memory-management candidate choices for Proposal B.
