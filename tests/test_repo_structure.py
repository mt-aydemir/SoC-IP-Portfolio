#!/usr/bin/env python3
"""Repository-level test: every IP directory is complete and consistent.

The portfolio promises a fixed layout for every IP. This test enforces it, so
an IP cannot be merged half-finished.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

REQUIRED_DIRS = ("rtl", "tb", "cocotb", "docs", "scripts")
REQUIRED_FILES = ("README.md", "LICENSE", "CHANGELOG.md", "CMakeLists.txt")


def check_ip(ip_dir: Path) -> list[str]:
    problems: list[str] = []
    rel = ip_dir.relative_to(ip_dir.parents[2])

    for name in REQUIRED_DIRS:
        if not (ip_dir / name).is_dir():
            problems.append(f"{rel}: missing directory '{name}/'")
    for name in REQUIRED_FILES:
        if not (ip_dir / name).is_file():
            problems.append(f"{rel}: missing file '{name}'")

    rtl = ip_dir / "rtl"
    if rtl.is_dir() and not list(rtl.glob("*.sv")):
        problems.append(f"{rel}: rtl/ contains no SystemVerilog source")

    cocotb_dir = ip_dir / "cocotb"
    if cocotb_dir.is_dir() and not list(cocotb_dir.glob("test_*.py")):
        problems.append(f"{rel}: cocotb/ contains no test_*.py module")

    docs = ip_dir / "docs"
    if docs.is_dir() and not (list(docs.glob("*.rst")) or list(docs.glob("*.md"))):
        problems.append(f"{rel}: docs/ contains no documentation source")

    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    args = parser.parse_args()

    ip_root = Path(args.root) / "ip"
    if not ip_root.is_dir():
        sys.stderr.write(f"no ip/ directory under {args.root}\n")
        return 1

    problems: list[str] = []
    ip_count = 0
    for category in sorted(p for p in ip_root.iterdir() if p.is_dir()):
        for ip_dir in sorted(p for p in category.iterdir() if p.is_dir()):
            ip_count += 1
            problems.extend(check_ip(ip_dir))

    if problems:
        for p in problems:
            sys.stderr.write(f"  {p}\n")
        sys.stderr.write(f"\n{len(problems)} structural problem(s) in {ip_count} IP(s)\n")
        return 1

    print(f"repo.structure PASS: {ip_count} IP(s) conform to the required layout")
    return 0


if __name__ == "__main__":
    sys.exit(main())
