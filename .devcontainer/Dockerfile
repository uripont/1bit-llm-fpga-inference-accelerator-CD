ARG DEVCONTAINER_PLATFORM=linux/amd64
FROM --platform=${DEVCONTAINER_PLATFORM} ubuntu:jammy

# Project-local lab image adapted from:
# https://github.com/Hardware-Forge/lab_DHWA

ARG VERIBLE_RELEASE=v0.0-4080-ga0a8d8eb
ARG RISCV_GCC_RELEASE=rv32i-131023
ARG RISCV_GCC_ARCHIVE=riscv32-unknown-elf.gcc-13.2.0.tar.gz

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV GIT_TERMINAL_PROMPT=0
ENV PATH=/opt/riscv/bin:${PATH}
ENV NEORV32_SETUPS=/opt/neorv32-setups

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    build-essential \
    curl \
    git \
    ghdl \
    iverilog \
    jq \
    libmpc3 \
    make \
    python3-pip \
    tar \
    universal-ctags \
    verilator \
    wget \
    xz-utils \
  && rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir \
    cocotb \
    cocotb-test \
    flake8 \
    isort \
    pytest \
    yapf

RUN wget -q "https://github.com/chipsalliance/verible/releases/download/${VERIBLE_RELEASE}/verible-${VERIBLE_RELEASE}-linux-static-x86_64.tar.gz" \
  && tar -C /usr/local --strip-components 1 -xf "verible-${VERIBLE_RELEASE}-linux-static-x86_64.tar.gz" \
  && rm "verible-${VERIBLE_RELEASE}-linux-static-x86_64.tar.gz"

RUN git clone --depth 1 https://github.com/stnolting/neorv32-setups.git "${NEORV32_SETUPS}" \
  && git -C "${NEORV32_SETUPS}" submodule update --init --recursive --depth 1 \
  && sed -i 's/RISCV_PREFIX ?= .*/RISCV_PREFIX ?= riscv32-unknown-elf-/g' "${NEORV32_SETUPS}/neorv32/sw/common/common.mk"

RUN mkdir -p /opt/riscv \
  && wget -q "https://github.com/stnolting/riscv-gcc-prebuilt/releases/download/${RISCV_GCC_RELEASE}/${RISCV_GCC_ARCHIVE}" \
  && tar -xzf "${RISCV_GCC_ARCHIVE}" -C /opt/riscv \
  && rm "${RISCV_GCC_ARCHIVE}"

WORKDIR /workspaces/1bit-llm-fpga-inference-accelerator-CD
