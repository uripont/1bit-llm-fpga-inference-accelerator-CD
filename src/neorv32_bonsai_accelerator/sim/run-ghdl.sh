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
IMEM_SIZE="${IMEM_SIZE:-16384}"
DMEM_SIZE="${DMEM_SIZE:-8192}"
STOP_TIME="${STOP_TIME:-15ms}"
SUCCESS_PATTERN="${SUCCESS_PATTERN:-shell_probe=PASS}"

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
  "${RTL_DIR}/local_buffer_bank.vhd" \
  "${RTL_DIR}/frontend_control.vhd" \
  "${RTL_DIR}/stream_frontend.vhd" \
  "${RTL_DIR}/stream_memory.vhd" \
  "${RTL_DIR}/memory_streamer.vhd" \
  "${RTL_DIR}/q1_matvec_engine.vhd" \
  "${RTL_DIR}/attn_kv_engine.vhd" \
  "${RTL_DIR}/bonsai_cfs_core.vhd" \
  "${RTL_DIR}/neorv32_cfs.vhd" \
  "${APP_IMAGE}"

while IFS= read -r -d '' source_file; do
  "${GHDL}" -i --std=08 --work=neorv32 --workdir="${BUILD_DIR}" \
    --ieee=standard "${source_file}"
done < <(find "${NEORV32_ROOT}/sim" -maxdepth 1 -type f -name '*.vhd' -print0)

echo "[2/3] Elaborating the complete NEORV32 testbench"
"${GHDL}" -m --std=08 --work=neorv32 --workdir="${BUILD_DIR}" neorv32_tb

echo "[3/3] Running the CFS firmware"
cd "${NEORV32_ROOT}/sim"
: > tb.uart0_rx.log
SIM_LOG="${BUILD_DIR}/shell-probe.log"
set +e
"${GHDL}" -r --std=08 --work=neorv32 --workdir="${BUILD_DIR}" neorv32_tb \
  -gJTAG_TESTS_EN=false \
  -gDUAL_CORE_EN=false \
  -gIMEM_SIZE="${IMEM_SIZE}" \
  -gDMEM_SIZE="${DMEM_SIZE}" \
  --max-stack-alloc=0 \
  --ieee-asserts=disable \
  --assert-level=error \
  --stop-time="${STOP_TIME}" > >(tee "${SIM_LOG}") 2>&1 &
SIM_PID=$!
SIM_STATUS=0
while kill -0 "${SIM_PID}" 2>/dev/null; do
  if grep -q "^${SUCCESS_PATTERN}$" "${SIM_LOG}"; then
    kill "${SIM_PID}" 2>/dev/null
    wait "${SIM_PID}" 2>/dev/null
    SIM_STATUS=0
    break
  fi
  sleep 0.2
done
if kill -0 "${SIM_PID}" 2>/dev/null; then
  wait "${SIM_PID}"
  SIM_STATUS=$?
elif ! grep -q "^${SUCCESS_PATTERN}$" "${SIM_LOG}"; then
  wait "${SIM_PID}"
  SIM_STATUS=$?
fi
set -e

if [[ ${SIM_STATUS} -ne 0 ]]; then
  exit "${SIM_STATUS}"
fi

grep -q "^${SUCCESS_PATTERN}$" "${SIM_LOG}"
echo "[pass] CFS firmware success marker: ${SUCCESS_PATTERN}"
