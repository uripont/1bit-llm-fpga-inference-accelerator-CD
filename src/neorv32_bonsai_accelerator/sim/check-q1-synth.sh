#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RTL_DIR="$(cd "${SCRIPT_DIR}/../rtl" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/synth-build"
GHDL="${GHDL:-ghdl}"

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"
trap 'rm -rf "${BUILD_DIR}"' EXIT

"${GHDL}" -a --std=08 --work=neorv32 --workdir="${BUILD_DIR}" \
  "${RTL_DIR}/bonsai_accel_pkg.vhd" \
  "${RTL_DIR}/q1_matvec_engine.vhd"
"${GHDL}" --synth --std=08 --work=neorv32 --workdir="${BUILD_DIR}" \
  q1_matvec_engine > /dev/null

echo "[pass] q1_matvec_engine is accepted by GHDL synthesis"
