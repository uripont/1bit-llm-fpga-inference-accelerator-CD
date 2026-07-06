# 1-bit LLM FPGA Inference Accelerator

#### Course project for "Design of Hardware Accelerators" at Politecnico di Milano, 2nd Semester 2026

This project started from a simple question: how fast can we run inference for a 1-bit LLM on an FPGA? The question is interesting because it touches on the intersection of model quantization, hardware design, frontier AI research, inference engineering, and the practical constraints of FPGA-based acceleration..

The initial motivation came from following the BitNet line of work, especially ["The Era of 1-bit LLMs"](https://arxiv.org/abs/2402.17764), and later seeing more practical low-bit model releases such as [BitNet b1.58 2B4T](https://arxiv.org/abs/2504.12285) and the [Bonsai/PrismML 1-bit models](https://prismml.com/news/bonsai-8b) even publicly discussed by [WSJ](https://www.wsj.com/cio-journal/caltech-researchers-claim-radical-compression-of-high-fidelity-ai-models-e66f31c9). Seeing recent work implementing [FPGA-based LLM inference accelerators](https://x.com/luthiraabeykoon/status/2050620806569361605) made me turn this initial predisposition and curiosity into direct attention for an optional course project.

Those models suggested an interesting hardware/software co-design direction: replace expensive multiply-heavy inference with packed bit operations, add/subtract accumulation, scaling, and carefully managed memory movement.

The course context was a NEORV32 hardware accelerator project. I wanted to explore whether a RISC-V control core (mandated by the course) plus a small custom datapath could be shaped around the structure of 1-bit-like LLM inference, to end up **considerably speeding up end-to-end throughput (average tokens/second).**

This README records the initial motivation around April 2026. The actual project scope, experiments, baselines, and accelerator design choices are developed separately in the repository.

## Lab Development Environment

The NEORV32 and HDL toolchain setup is documented in [docs/lab-dev-container-setup.md](docs/lab-dev-container-setup.md). The project-local Dev Container is adapted from the official `Hardware-Forge/lab_DHWA` course setup and uses a unique container name to avoid conflicts with the standalone lab repository.
