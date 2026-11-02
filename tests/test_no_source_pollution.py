#!/usr/bin/env python3
"""Repository-level test: no build artefact ever lands in the source tree.

The portfolio rule is absolute - everything generated goes under build/.
This test walks the tracked source directories looking for the debris that
EDA and Python tooling leaves behind when a flow is run from the wrong
working directory.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

# Directories that legitimately contain generated content or are not source.
EXCLUDED_DIRS = {"build", ".git", ".venv", "venv", "__pycache__", ".pytest_cache"}

FORBIDDEN_SUFFIXES = {
    ".vcd", ".fst", ".ghw", ".shm",          # waveforms
    ".o", ".d", ".a", ".so", ".exe",         # compiled objects
    ".jou", ".log", ".blif", ".edif",        # tool journals / netlists
    ".xml",                                  # cocotb results
}

FORBIDDEN_NAMES = {
    "sim_build", "obj_dir", "results.xml", "dump.vcd",
    "yosys.log", "verilator.log", "Vtop", "cmake-build-debug",
}

# Files that legitimately carry a forbidden suffix.
ALLOWED_PATHS = {
    Path(".github/workflows"),
    Path("docs"),
}


def is_allowed(rel: Path) -> bool:
    return any(rel.is_relative_to(prefix) for prefix in ALLOWED_PATHS)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    args = parser.parse_args()

    root = Path(os.path.abspath(args.root))
    offenders: list[str] = []

    for path in root.rglob("*"):
        rel = path.relative_to(root)
        if any(part in EXCLUDED_DIRS for part in rel.parts):
            continue
        if is_allowed(rel):
            continue
        if path.is_dir():
            if path.name in FORBIDDEN_NAMES:
                offenders.append(f"{rel}/  (generated directory in source tree)")
        elif path.suffix in FORBIDDEN_SUFFIXES or path.name in FORBIDDEN_NAMES:
            offenders.append(f"{rel}  (generated file in source tree)")

    if offenders:
        for o in sorted(offenders):
            sys.stderr.write(f"  {o}\n")
        sys.stderr.write(
            f"\n{len(offenders)} generated artefact(s) found in the source tree.\n"
            "All tool output must be written under build/.\n")
        return 1

    print("repo.no_source_pollution PASS: source tree is free of build artefacts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
