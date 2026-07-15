#!/usr/bin/env python3
"""Evaluate Proposal B MEM_STREAM using the shared attention evaluator."""

import runpy
import sys
from pathlib import Path

sys.argv.extend(["--transfer-mode", "mem_stream"])
runpy.run_path(
    Path(__file__).with_name("evaluate-attention-kv-cpu-push.py"),
    run_name="__main__",
)
