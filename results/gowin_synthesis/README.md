# Gowin synthesis evidence

These files preserve the raw Gowin FPGA Designer Education V1.9.11.03 reports
used by the final accelerator evaluation. All profiles target
`GW1NR-LV9QN88PC6/I5` with a 27 MHz system-clock constraint.

The proposal-specific projects use trimmed SoC configurations. Their resource
figures represent each complete profile and should not be subtracted to infer
isolated engine cost.

- `proposal_a/pnr-report.txt`: routed resource and pin report for the Q1/Q8
  accelerator profile.
- `proposal_a/timing-report.html`: routed timing analysis for Proposal A.
- `proposal_b_cpu_push/pnr-report.txt`: routed resource and pin report for the
  attention engine with the CPU-push frontend.
- `proposal_b_cpu_push/timing-report.html`: routed timing analysis for Proposal
  B CPU push.
- `proposal_b_mem_stream/synthesis.log`: synthesis log for the attention engine,
  descriptor streamer, PLL and generated DQ16 PSRAM controller. Gowin stops at
  the device-capacity check, so this profile has no place-and-route, timing, or
  PSRAM pin-placement report.

The reproducible project definitions are under
`src/neorv32_bonsai_accelerator/gowin/`.
