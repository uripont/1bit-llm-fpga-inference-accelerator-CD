#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/neorv32_imem_image.vhd" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACCEL_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${ACCEL_ROOT}/../.." && pwd)"
NEORV32_ROOT="${REPO_ROOT}/neorv32-setups/neorv32"
RTL_DIR="${ACCEL_ROOT}/rtl"
BUILD_DIR="${SCRIPT_DIR}/build"
APP_IMAGE="$(realpath "$1")"
GHDL="${GHDL:-ghdl}"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

echo "[1/3] Importing NEORV32 and Bonsai accelerator RTL"
while IFS= read -r -d '' source_file; do
  "${GHDL}" -i --std=08 --work=neorv32 --workdir="${BUILD_DIR}" \
    --ieee=standard "${source_file}"
done < <(find "${NEORV32_ROOT}/rtl/core" -type f -name '*.vhd' \
  ! -name 'neorv32_cfs.vhd' ! -name 'neorv32_imem_image.vhd' -print0)

"${GHDL}" -i --std=08 --work=neorv32 --workdir="${BUILD_DIR}" \
  --ieee=standard "${RTL_DIR}/bonsai_accel_pkg.vhd" \
  "${RTL_DIR}/cfs_reg_file.vhd" \
  "${RTL_DIR}/accel_top.vhd" \
  "${RTL_DIR}/counter_block.vhd" \
  "${RTL_DIR}/stream_frontend.vhd" \
  "${RTL_DIR}/shell_test_engine.vhd" \
  "${RTL_DIR}/neorv32_cfs.vhd" \
  "${APP_IMAGE}"

while IFS= read -r -d '' source_file; do
  "${GHDL}" -i --std=08 --work=neorv32 --workdir="${BUILD_DIR}" \
    --ieee=standard "${source_file}"
done < <(find "${NEORV32_ROOT}/sim" -maxdepth 1 -type f -name '*.vhd' -print0)

echo "[2/3] Elaborating the complete NEORV32 testbench"
"${GHDL}" -m --std=08 --work=neorv32 --workdir="${BUILD_DIR}" neorv32_tb

echo "[3/3] Running the CFS firmware probe"
cd "${NEORV32_ROOT}/sim"
: > tb.uart0_rx.log
SIM_LOG="${BUILD_DIR}/shell-probe.log"
"${GHDL}" -r --std=08 --work=neorv32 --workdir="${BUILD_DIR}" neorv32_tb \
  -gJTAG_TESTS_EN=false \
  -gDUAL_CORE_EN=false \
  -gIMEM_SIZE=16384 \
  -gDMEM_SIZE=8192 \
  --max-stack-alloc=0 \
  --ieee-asserts=disable \
  --assert-level=error \
  --stop-time=2ms | tee "${SIM_LOG}"

grep -q '^shell_probe=PASS$' "${SIM_LOG}"
echo "[pass] Bonsai accelerator CFS register contract"
