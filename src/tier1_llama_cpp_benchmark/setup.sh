#!/usr/bin/env bash
set -euo pipefail

# Run from the repository root, regardless of where the script is invoked.
cd "$(dirname "$0")/../.."

# External llama.cpp dependency. The commit is pinned so the profiling patch is
# reproducible instead of depending on whatever upstream looks like later.
LLAMA_REPO="${LLAMA_REPO:-external/llama.cpp}"
LLAMA_REMOTE="${LLAMA_REMOTE:-https://github.com/ggml-org/llama.cpp}"
LLAMA_COMMIT="${LLAMA_COMMIT:-1ec7ba0c14f33f17e980daeeda5f35b225d41994}"
BUILD_DIR="${BUILD_DIR:-$LLAMA_REPO/build-cpu}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"
PATCH="src/tier1_llama_cpp_benchmark/q1-profile.patch"
MODEL="${MODEL:-models/bonsai-1.7b-gguf/Bonsai-1.7B-Q1_0.gguf}"
MODEL_SOURCE="${MODEL_SOURCE:-}"
HF_REPO="${HF_REPO:-prism-ml/Bonsai-1.7B-gguf}"
HF_FILE="${HF_FILE:-Bonsai-1.7B-Q1_0.gguf}"
HF_REVISION="${HF_REVISION:-210a9e99f79cb184909d49595906526eb2b3dd9a}"
HF_SHA256="${HF_SHA256:-3d7c6c90dd98717a203adb22d5eacd2581850e40aa5327e144b97766cae5f7e3}"
HF_URL="${HF_URL:-https://huggingface.co/$HF_REPO/resolve/$HF_REVISION/$HF_FILE}"
REPO_PARENT="$(cd .. && pwd)"
DESKTOP_SOURCE="$REPO_PARENT/1bit-llm-inference-accelerator/$MODEL"

# Prepare the default model path used by the run scripts. The GGUF is too large
# to vendor in this small repo, so setup downloads it from Hugging Face. Pass
# MODEL_SOURCE=/path/to/Bonsai-...gguf to link an existing local copy instead.
if [[ ! -f "$MODEL" ]]; then
  if [[ -n "$MODEL_SOURCE" && -f "$MODEL_SOURCE" ]]; then
    mkdir -p "$(dirname "$MODEL")"
    ln -sf "$MODEL_SOURCE" "$MODEL"
    echo "linked model: $MODEL -> $MODEL_SOURCE"
  else
    mkdir -p "$(dirname "$MODEL")"
    tmp_model="$MODEL.download"
    echo "downloading model from Hugging Face:"
    echo "  $HF_URL"
    # Small Python snippet to show progress because curl/wget are not guaranteed to be present.
    if python3 - "$HF_URL" "$tmp_model" <<'PY'
import shutil
import sys
import time
import urllib.request

url, out = sys.argv[1], sys.argv[2]
last_report = 0.0

with urllib.request.urlopen(url) as response, open(out, "wb") as handle:
    total = int(response.headers.get("Content-Length") or 0)
    read = 0
    while True:
        chunk = response.read(1024 * 1024)
        if not chunk:
            break
        handle.write(chunk)
        read += len(chunk)
        now = time.time()
        if now - last_report >= 2.0:
            if total:
                print(f"  downloaded {read / 1e6:.1f}/{total / 1e6:.1f} MB", flush=True)
            else:
                print(f"  downloaded {read / 1e6:.1f} MB", flush=True)
            last_report = now
PY
    then
      mv "$tmp_model" "$MODEL"
      echo "downloaded model: $MODEL"
    elif [[ -f "$DESKTOP_SOURCE" ]]; then
      rm -f "$tmp_model"
      ln -sf "$DESKTOP_SOURCE" "$MODEL"
      echo "download failed; linked existing local model instead:"
      echo "  $MODEL -> $DESKTOP_SOURCE"
    else
      rm -f "$tmp_model"
      echo "error: failed to download model and no local fallback was found" >&2
      echo "set MODEL_SOURCE=/path/to/Bonsai-...gguf, or check network access to Hugging Face" >&2
      exit 1
    fi
  fi
fi

if command -v sha256sum >/dev/null 2>&1; then
  model_sha256="$(sha256sum "$MODEL" | awk '{print $1}')"
else
  model_sha256="$(shasum -a 256 "$MODEL" | awk '{print $1}')"
fi
if [[ "$model_sha256" != "$HF_SHA256" ]]; then
  echo "error: model SHA-256 mismatch" >&2
  echo "  expected: $HF_SHA256" >&2
  echo "  actual:   $model_sha256" >&2
  exit 1
fi
echo "verified model SHA-256: $model_sha256"

# Clone llama.cpp only if the expected checkout is not already present.
if [[ ! -d "$LLAMA_REPO/.git" ]]; then
  mkdir -p "$(dirname "$LLAMA_REPO")"
  git clone "$LLAMA_REMOTE" "$LLAMA_REPO"
fi

git -C "$LLAMA_REPO" checkout "$LLAMA_COMMIT"

# Apply the profiling patch unless it is already present. The patch adds
# operation-level CPU/BLAS timing but does not change the benchmark interface.
if git -C "$LLAMA_REPO" apply --reverse --check "../../$PATCH" >/dev/null 2>&1; then
  echo "profiling patch already applied"
else
  git -C "$LLAMA_REPO" apply "../../$PATCH"
fi

# CPU-only build. Accelerate/BLAS is enabled because this is the realistic
# Mac CPU baseline; Metal is disabled so the run is not a GPU baseline.
cmake -S "$LLAMA_REPO" -B "$BUILD_DIR" \
  -DGGML_METAL=OFF \
  -DGGML_ACCELERATE=ON \
  -DGGML_BLAS=ON \
  -DLLAMA_CURL=OFF

cmake --build "$BUILD_DIR" --target llama-cli llama-batched-bench -j "$JOBS"

echo "built:"
echo "  $BUILD_DIR/bin/llama-cli"
echo "  $BUILD_DIR/bin/llama-batched-bench"
