# Reproducibility

This file records the external revisions and generated-input provenance used by the committed results. The large model and external source trees remain ignored; the scripts and hashes below recreate or verify them.

## Model And CPU Runtime

- Model repository: `prism-ml/Bonsai-1.7B-gguf`
- Model revision: `210a9e99f79cb184909d49595906526eb2b3dd9a`
- Model file: `Bonsai-1.7B-Q1_0.gguf`
- File size: `248302272` bytes
- SHA-256: `3d7c6c90dd98717a203adb22d5eacd2581850e40aa5327e144b97766cae5f7e3`
- llama.cpp commit: `1ec7ba0c14f33f17e980daeeda5f35b225d41994`
- Tier 1 host: Apple M1 Pro MacBook Pro, six benchmark threads, CPU backend
  with Accelerate/BLAS enabled and Metal disabled.

`src/tier1_llama_cpp_benchmark/setup.sh` downloads the revision-qualified model and refuses to continue when its SHA-256 differs. It also checks out the pinned llama.cpp commit before applying the committed profiling patch.

## NEORV32 And Container Toolchain

- `neorv32-setups`: `02646bdf8559eded9f8dcb665d9a8990b5aee4ee`
- `neorv32` submodule: `3e34652f559c16013b84438af8dedb07ce7e5773`
  (`v1.13.2`)
- `constraints` submodule: `cd6ebf23edb1209c98b7d88b7167a4707e5372ef`
- RISC-V GCC bundle: `rv32i-131023`, GCC 13.2.0 archive
- Verible release: `v0.0-4080-ga0a8d8eb`
- Simulation tools are installed by `.devcontainer/Dockerfile` on Ubuntu 22.04
  for `linux/amd64`.

The Dockerfile fetches the pinned `neorv32-setups` commit and its recorded submodules. The post-create hook exposes it at the repository-local `neorv32-setups` path used by the simulation scripts.

## Tier 3 Fixture

The committed fixture is self-contained at `src/tier3_neorv32_cycle_kernels/generated/tier3_bonsai_fixture.h`. Its exact tensor and row mapping is documented beside the fixture in `generated/README.md`. The fixture header is sufficient for Tier 3 and Proposal A reruns; access to the GGUF is needed only to independently verify its origin.

## RTL and board synthesis

- Simulator: the GHDL/NEORV32 flow installed by the pinned devcontainer.
- FPGA: Gowin `GW1NR-LV9QN88PC6/I5`, Tang Nano 9K, 27 MHz constraint.
- Synthesis: Gowin FPGA Designer Education V1.9.11.03.

Cycle evaluations use the running devcontainer through the host-side drivers in `src/neorv32_bonsai_accelerator/README.md`. Gowin project creation and synthesis steps are documented in `src/neorv32_bonsai_accelerator/gowin/README.md`. Raw evaluation and synthesis evidence is committed under `results/`.
