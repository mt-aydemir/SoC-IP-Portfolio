#!/usr/bin/env python3
"""Repository-level test: RTL coding-style rules that Verilator cannot check.

Enforces the portfolio's house rules:
  * one module per file, module name equals file name
  * a licence header on every source file
  * `default_nettype none is in force around the module
  * no vendor-specific primitives or attributes
  * no unfinished-work markers in released RTL
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

MODULE_RE = re.compile(r"^\s*module\s+([A-Za-z_]\w*)", re.MULTILINE)
TODO_RE = re.compile(r"\b(TODO|FIXME|XXX|HACK|PLACEHOLDER)\b")

# Primitives and attributes that tie RTL to one vendor. The portfolio is
# vendor independent: anything here is a hard error.
VENDOR_PATTERNS = {
    "Xilinx primitive": re.compile(
        r"\b(BUFG|BUFGCE|IBUFG|OBUFT?|MMCME\d|PLLE\d|RAMB\d+|DSP48E\d|"
        r"FDRE|FDCE|SRL16E|SRLC32E|IDDR|ODDR|CARRY4|LUT[1-6])\b"),
    "Intel/Altera primitive": re.compile(
        r"\b(altsyncram|altpll|alt_pll|lpm_\w+|cyclone\w*|stratix\w*|"
        r"altera_\w+|arriav\w*)\b", re.IGNORECASE),
    "Lattice primitive": re.compile(r"\b(SB_\w+|EHXPLLL|DP16KD|PDPW16KD)\b"),
    "vendor attribute": re.compile(
        r"\(\*\s*(ram_style|rom_style|use_dsp|shreg_extract|ASYNC_REG|"
        r"syn_\w+|altera_attribute|dont_touch|keep_hierarchy)\b",
        re.IGNORECASE),
}


def check_file(path: Path, root: Path) -> list[str]:
    problems: list[str] = []
    rel = path.relative_to(root)
    text = path.read_text(encoding="utf-8", errors="replace")

    modules = MODULE_RE.findall(text)
    if len(modules) != 1:
        problems.append(
            f"{rel}: expected exactly one module per file, found {len(modules)} "
            f"{modules}")
    elif modules[0] != path.stem:
        problems.append(
            f"{rel}: module '{modules[0]}' does not match file name '{path.stem}'")

    if "SPDX-License-Identifier" not in text:
        problems.append(f"{rel}: missing SPDX-License-Identifier header")

    if "`default_nettype none" not in text:
        problems.append(f"{rel}: must set `default_nettype none")
    elif "`default_nettype wire" not in text:
        problems.append(
            f"{rel}: must restore `default_nettype wire at end of file")

    for label, pattern in VENDOR_PATTERNS.items():
        match = pattern.search(text)
        if match:
            line = text[:match.start()].count("\n") + 1
            problems.append(
                f"{rel}:{line}: {label} '{match.group(0)}' breaks vendor independence")

    for match in TODO_RE.finditer(text):
        line = text[:match.start()].count("\n") + 1
        problems.append(
            f"{rel}:{line}: '{match.group(0)}' marker in released RTL")

    if "\t" in text:
        line = text[:text.index("\t")].count("\n") + 1
        problems.append(f"{rel}:{line}: tab character (use spaces)")

    for number, line_text in enumerate(text.splitlines(), start=1):
        if len(line_text) > 100:
            problems.append(f"{rel}:{number}: line exceeds 100 columns "
                            f"({len(line_text)})")
            break

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    args = parser.parse_args()

    root = Path(args.root)
    sources = sorted((root / "ip").rglob("rtl/*.sv"))
    if not sources:
        sys.stderr.write("no RTL sources found under ip/*/*/rtl/\n")
        return 1

    problems: list[str] = []
    for path in sources:
        problems.extend(check_file(path, root))

    if problems:
        for p in problems:
            sys.stderr.write(f"  {p}\n")
        sys.stderr.write(f"\n{len(problems)} style problem(s) in "
                         f"{len(sources)} file(s)\n")
        return 1

    print(f"repo.rtl_style PASS: {len(sources)} RTL file(s) conform to the house style")
    return 0


if __name__ == "__main__":
    sys.exit(main())
