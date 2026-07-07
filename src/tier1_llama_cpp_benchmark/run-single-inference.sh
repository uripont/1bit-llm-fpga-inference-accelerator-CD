#!/usr/bin/env bash
set -euo pipefail

# Run one human-readable generation with the Bonsai/Q1_0 model.
#
# Usage:
#   src/tier1_llama_cpp_benchmark/run-single-inference.sh [prompt] [max_completion_tokens]
#
# The same values can also be passed through environment variables:
#   PROMPT="..." MAX_COMPLETION_LENGTH=384 src/tier1_llama_cpp_benchmark/run-single-inference.sh

cd "$(dirname "$0")/../.."

MODEL="${MODEL:-models/bonsai-1.7b-gguf/Bonsai-1.7B-Q1_0.gguf}"
BIN="${BIN:-external/llama.cpp/build-cpu/bin/llama-cli}"
THREADS="${THREADS:-6}"
N_CTX="${N_CTX:-1024}"
TEMP="${TEMP:-0.7}"
TOP_P="${TOP_P:-0.9}"
DEFAULT_PROMPT="In two short paragraphs, explain why a small 1-bit language model is an interesting baseline for a CPU-only edge inference accelerator project."
PROMPT="${1:-${PROMPT:-$DEFAULT_PROMPT}}"
N_PREDICT="${2:-${MAX_COMPLETION_LENGTH:-${N_PREDICT:-384}}}"

if [[ ! -x "$BIN" ]]; then
  echo "missing llama-cli: $BIN" >&2
  echo "run src/tier1_llama_cpp_benchmark/setup.sh first, or set BIN=/path/to/llama-cli" >&2
  exit 1
fi

if [[ ! -f "$MODEL" ]]; then
  echo "missing model: $MODEL" >&2
  echo "set MODEL=/path/to/Bonsai-...gguf" >&2
  exit 1
fi

"$BIN" \
  -m "$MODEL" \
  -t "$THREADS" \
  -c "$N_CTX" \
  -n "$N_PREDICT" \
  --temp "$TEMP" \
  --top-p "$TOP_P" \
  --single-turn \
  --no-display-prompt \
  -p "$PROMPT"
