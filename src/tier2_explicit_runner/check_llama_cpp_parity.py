#!/usr/bin/env python3
"""Basic Tier 2 vs llama.cpp decode parity checks.

This script compares the self-contained runner against llama.cpp's debug tool:
1. llama-debug tokenizes a text prompt and saves final logits.
2. bonsai-explicit-runner decodes the same token ids.
3. The script compares the final top-k tokens, logits, and probabilities.
"""

from __future__ import annotations

import argparse
import math
import os
import re
import struct
import subprocess
import tempfile
from pathlib import Path


def run(cmd: list[str], cwd: Path) -> str:
    result = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            "command failed:\n"
            + " ".join(cmd)
            + "\nstdout:\n"
            + result.stdout
            + "\nstderr:\n"
            + result.stderr
        )
    return result.stdout + result.stderr


def build_runner(repo: Path, source: Path, runner: Path) -> None:
    run(
        [
            "c++",
            "-std=c++17",
            "-O3",
            "-Wall",
            "-Wextra",
            "-Wpedantic",
            str(source),
            "-o",
            str(runner),
        ],
        repo,
    )


def parse_prompt_tokens(prompt_file: Path) -> list[int]:
    text = prompt_file.read_text()
    match = re.search(r"token ids:\s*([0-9,\s-]+)", text)
    if not match:
        raise RuntimeError(f"could not parse token ids from {prompt_file}")
    return [int(item.strip()) for item in match.group(1).split(",") if item.strip()]


def top_from_logits(logit_file: Path, k: int, vocab_size: int) -> list[tuple[int, float, float]]:
    data = logit_file.read_bytes()
    logits = list(struct.unpack("<%df" % (len(data) // 4), data))
    if len(logits) % vocab_size != 0:
        raise RuntimeError(f"logit file does not contain whole vocab rows: {logit_file}")
    logits = logits[-vocab_size:]
    max_logit = max(logits)
    denom = sum(math.exp(value - max_logit) for value in logits)
    indices = sorted(range(len(logits)), key=lambda i: logits[i], reverse=True)[:k]
    return [(i, logits[i], math.exp(logits[i] - max_logit) / denom) for i in indices]


def parse_runner_top(output: str, k: int) -> list[tuple[int, float, float]]:
    current: list[tuple[int, float, float]] = []
    last: list[tuple[int, float, float]] = []
    pattern = re.compile(r"top_token rank=(\d+) token=(\d+) probability=([0-9.eE+-]+) logit=([0-9.eE+-]+)")
    for line in output.splitlines():
        match = pattern.search(line)
        if not match:
            continue
        rank = int(match.group(1))
        if rank == 1:
            current = []
        current.append((int(match.group(2)), float(match.group(4)), float(match.group(3))))
        last = current
    if not last:
        raise RuntimeError("runner output did not contain top_token rows")
    return last[:k]


def compare(
    prompt: str,
    reference: list[tuple[int, float, float]],
    actual: list[tuple[int, float, float]],
    logit_tol: float,
    prob_tol: float,
    policy: str,
    min_overlap: int,
) -> None:
    ref_tokens = [item[0] for item in reference]
    act_tokens = [item[0] for item in actual]

    if policy == "top1-overlap":
        if ref_tokens[0] != act_tokens[0]:
            raise RuntimeError(f"top-1 differs for prompt {prompt!r}: llama.cpp={ref_tokens[0]}, tier2={act_tokens[0]}")
        overlap = len(set(ref_tokens) & set(act_tokens))
        if overlap < min_overlap:
            raise RuntimeError(f"top token overlap too low for prompt {prompt!r}: overlap={overlap}, llama.cpp={ref_tokens}, tier2={act_tokens}")
    elif policy == "top-k-overlap":
        overlap = len(set(ref_tokens) & set(act_tokens))
        if overlap < min_overlap:
            raise RuntimeError(f"top token overlap too low for prompt {prompt!r}: overlap={overlap}, llama.cpp={ref_tokens}, tier2={act_tokens}")
    elif policy == "exact":
        if ref_tokens != act_tokens:
            raise RuntimeError(f"top tokens differ for prompt {prompt!r}: llama.cpp={ref_tokens}, tier2={act_tokens}")
    else:
        raise RuntimeError(f"unsupported comparison policy: {policy}")

    for rank, (ref, act) in enumerate(zip(reference, actual), start=1):
        token_ref, logit_ref, prob_ref = ref
        token_act, logit_act, prob_act = act
        if policy in {"top1-overlap", "top-k-overlap"} and rank > 1:
            continue
        if policy == "top-k-overlap":
            continue
        if token_ref != token_act:
            raise RuntimeError(f"rank {rank} token differs for prompt {prompt!r}: llama.cpp={token_ref}, tier2={token_act}")
        logit_err = abs(logit_ref - logit_act)
        prob_err = abs(prob_ref - prob_act)
        if logit_err > logit_tol or prob_err > prob_tol:
            raise RuntimeError(
                f"rank {rank} token {token_ref} differs for prompt {prompt!r}: "
                f"logit_err={logit_err:.6g}, prob_err={prob_err:.6g}, "
                f"llama=({logit_ref:.6g}, {prob_ref:.6g}), tier2=({logit_act:.6g}, {prob_act:.6g})"
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--model", type=Path, default=Path("models/bonsai-1.7b-gguf/Bonsai-1.7B-Q1_0.gguf"))
    parser.add_argument("--llama-debug", type=Path, default=Path("external/llama.cpp/build-cpu/bin/llama-debug"))
    parser.add_argument("--runner", type=Path, default=Path("/tmp/bonsai-explicit-runner-parity"))
    parser.add_argument("--top-k", type=int, default=5)
    parser.add_argument("--logit-tol", type=float, default=0.08)
    parser.add_argument("--prob-tol", type=float, default=0.02)
    parser.add_argument("--policy", choices=["exact", "top1-overlap", "top-k-overlap"], default="exact")
    parser.add_argument("--min-overlap", type=int, default=4)
    parser.add_argument("--vocab-size", type=int, default=151669)
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("prompts", nargs="*", default=["!", "!!", "Hello"])
    args = parser.parse_args()

    repo = args.repo.resolve()
    model = args.model if args.model.is_absolute() else repo / args.model
    llama_debug = args.llama_debug if args.llama_debug.is_absolute() else repo / args.llama_debug
    source = repo / "src/tier2_explicit_runner/bonsai-explicit-runner.cpp"
    runner = args.runner

    if not llama_debug.exists():
      raise RuntimeError(f"llama-debug not found: {llama_debug}; build target llama-debug first")

    build_runner(repo, source, runner)

    with tempfile.TemporaryDirectory(prefix="bonsai-tier2-parity-") as tmp:
        tmpdir = Path(tmp)
        for idx, prompt in enumerate(args.prompts):
            outdir = tmpdir / f"llama-{idx}"
            run(
                [
                    str(llama_debug),
                    "-m",
                    str(model),
                    "-p",
                    prompt,
                    "--save-logits",
                    "--logits-output-dir",
                    str(outdir),
                    "--no-warmup",
                    "--threads",
                    "6",
                    "--threads-batch",
                    "6",
                    "--ctx-size",
                    "64",
                    "--batch-size",
                    "64",
                    "--ubatch-size",
                    "64",
                    "--no-mmap",
                ],
                repo,
            )
            stem = "llamacpp-" + model.stem
            tokens = parse_prompt_tokens(outdir / f"{stem}-prompt.txt")
            reference = top_from_logits(outdir / f"{stem}.bin", args.top_k, args.vocab_size)
            runner_output = run(
                [
                    str(runner),
                    "--model",
                    str(model),
                    "--trace-one-token",
                    "--tokens",
                    ",".join(map(str, tokens)),
                    "--top-k",
                    str(args.top_k),
                ],
                repo,
            )
            actual = parse_runner_top(runner_output, args.top_k)
            compare(prompt, reference, actual, args.logit_tol, args.prob_tol, args.policy, args.min_overlap)
            if args.verbose:
                print(f"  llama.cpp top={[(token, round(logit, 5), round(prob, 6)) for token, logit, prob in reference]}")
                print(f"  tier2     top={[(token, round(logit, 5), round(prob, 6)) for token, logit, prob in actual]}")
            print(f"ok prompt={prompt!r} tokens={tokens} top={[token for token, _, _ in actual]}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
