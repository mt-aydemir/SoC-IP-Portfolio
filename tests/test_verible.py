#!/usr/bin/env python3
"""Repository-level test: Verible lint over every SystemVerilog source.

Verilator's -Wall lint (stage 1) checks what a simulator and synthesiser
care about. Verible checks the language and the style a standard parser
expects: reserved words used as names, untyped parameters and function
arguments, implicit function lifetimes, naming, line length.

The rules are in .rules.verible_lint at the repository root and the few
exceptions, each with its reason, in verible.waive. Formatting is not
checked: the formatter would rewrite almost every file and lose the
deliberate alignment, so the style guide governs layout instead.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

PATTERNS = (
    "ip/*/*/rtl/*.sv",
    "ip/*/*/tb/*.sv",
    "ip/*/*/formal/*.sv",
    "ip/*/*/uvm/*.sv",
    "examples/*/rtl/*.sv",
    "templates/*/rtl/*.sv",
    "templates/*/tb/*.sv",
)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--root", required=True)
    p.add_argument("--verible", required=True, help="verible-verilog-lint")
    args = p.parse_args()
    root = Path(os.path.abspath(args.root))

    files = sorted({f for pattern in PATTERNS for f in root.glob(pattern)})
    if not files:
        sys.stderr.write("repo.verible FAIL: no SystemVerilog source found\n")
        return 1

    # Run from the root so that findings name repository-relative paths and
    # the waivers' location patterns match them.
    proc = subprocess.run(
        [args.verible,
         f"--rules_config={root / '.rules.verible_lint'}",
         f"--waiver_files={root / 'verible.waive'}",
         *(f.relative_to(root).as_posix() for f in files)],
        cwd=root, capture_output=True, text=True)
    output = (proc.stdout + proc.stderr).strip()
    if proc.returncode != 0 or output:
        print(output)
        findings = len(output.splitlines())
        sys.stderr.write(f"\nrepo.verible FAIL: {findings} finding(s) in {len(files)} file(s)\n")
        return 1

    print(f"repo.verible PASS: {len(files)} SystemVerilog file(s) are Verible-clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
