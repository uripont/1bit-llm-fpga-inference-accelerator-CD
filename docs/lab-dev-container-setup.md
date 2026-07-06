# Lab Dev Container Setup

This project uses a local Dev Container setup adapted from the [official course repository](https://github.com/Hardware-Forge/lab_DHWA). The container provides the NEORV32 software flow and HDL tools used in the Design of Hardware Accelerators labs.

## Prerequisites

- Docker Desktop running.
- VS Code with the Dev Containers extension installed.
- The `ubuntu:jammy` image available for `linux/amd64`.

On Apple Silicon, the lab container must run as `linux/amd64` because the RISC-V GCC prebuilt from `stnolting/riscv-gcc-prebuilt` is an x86_64 Linux binary.

## Start The Environment

Open this repository in VS Code:

```sh
cd /Users/uripont/Desktop/1bit-llm-fpga-inference-accelerator-CD
code .
```

Then run:

```text
Dev Containers: Rebuild and Reopen in Container
```

This repository builds the Docker image with the stable local tag `1bit-llm-fpga-dev:latest` before VS Code creates the container. That avoids relying on VS Code's generated `vsc-...` image tag and makes the image easier to test from a terminal.

The container name is `1bit-llm-fpga-dev`, so it does not conflict with the official `lab_DHWA` container name `hardware-dev`.

The first rebuild downloads and installs the lab toolchain into a Docker image, so it can take several minutes. Later reopens reuse the image and should be much faster.

## Verify setup

Inside the VS Code container terminal:

```sh
riscv32-unknown-elf-gcc --version
ghdl --version
verilator --version
verible-verilog-format --version
```

Build a NEORV32 example:

```sh
cd neorv32-setups/neorv32/sw/example/demo_blink_led
make clean all
```

Expected result includes:

```text
neorv32_exe.bin
neorv32_imem_image.vhd
```