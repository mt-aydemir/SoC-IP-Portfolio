#!/usr/bin/env python3
"""Code coverage report.

With SOC_IP_ENABLE_COVERAGE on, the cocotb and SystemVerilog testbench runs
are built with ``verilator --coverage`` and each leaves a ``coverage.dat``.

``report`` merges every data file of one IP and counts the line, branch and
toggle points of that IP's own RTL: dependencies and testbenches are left out,
so a block is not credited for code that belongs to another block.

A point is identified by its file, line, column, kind and description, not by
its hierarchy. The testbenches instantiate the block under different names and
at different parameters, and a block instantiated twice has each point twice;
a point counts as covered when any of its instances was hit.

Verilator also gives an assertion's declaration and its failure action a line
point. Hitting one would mean the assertion failed, so they are not counted.

``summary`` prints one table from the JSON the reports left behind.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

KINDS = {"v_line": "line", "v_branch": "branch", "v_toggle": "toggle"}
HEADER = "# SystemC::Coverage"
ASSERTION_RE = re.compile(
    r"^\s*(?:\w+\s*:\s*)?(?:property|sequence|assert|assume|cover)\b"
    r"|\$(?:error|fatal)\b")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="command", required=True)

    r = sub.add_parser("report", help="report one IP")
    r.add_argument("--name", required=True)
    r.add_argument("--category", required=True)
    r.add_argument("--data-dir", action="append", required=True,
                   help="directory searched for coverage.dat")
    r.add_argument("--report-dir", required=True)
    r.add_argument("--sources", nargs="+", required=True,
                   help="the IP's own RTL")

    s = sub.add_parser("summary", help="print every IP's result")
    s.add_argument("--report-dir", required=True)
    return p.parse_args()


def parse_key(key: str) -> dict[str, str]:
    """Split a point's key: \\x01 before each field, \\x02 before its value."""
    fields = {}
    for field in key.split("\x01"):
        name, sep, value = field.partition("\x02")
        if sep:
            fields[name] = value
    return fields


def assertion_lines(path: str) -> set[int]:
    """Line numbers of ``path`` that belong to assertions, not to the design."""
    with open(path, encoding="utf-8") as handle:
        return {n for n, line in enumerate(handle, 1) if ASSERTION_RE.search(line)}


def read_points(data: Path, sources: dict[str, set[int]],
                points: dict[tuple, int]) -> None:
    """Add one data file's points of ``sources`` to ``points``."""
    with data.open(encoding="utf-8", errors="surrogateescape") as handle:
        first = handle.readline()
        if not first.startswith(HEADER):
            raise ValueError(f"{data}: not a coverage file")
        for line in handle:
            if not line.startswith("C '"):
                continue
            key, _, count = line[3:].rpartition("' ")
            fields = parse_key(key)
            kind = KINDS.get(fields.get("page", "").partition("/")[0])
            path = os.path.realpath(fields.get("f", ""))
            if kind is None or path not in sources:
                continue
            number = int(fields.get("l", 0))
            if kind == "line" and number in sources[path]:
                continue
            point = (kind, path, number, fields.get("n", ""), fields.get("o", ""))
            points[point] = points.get(point, 0) + int(count)


def percent(hit: int, total: int) -> float | None:
    return round(100.0 * hit / total, 1) if total else None


def report(args: argparse.Namespace) -> int:
    # Real paths on both sides: cocotb records sources with symlinks resolved
    # and the SystemVerilog testbench does not, so a checkout reached through
    # a symlink would otherwise lose one testbench's points.
    sources = {os.path.realpath(s): assertion_lines(s) for s in args.sources}
    files = sorted(f for d in args.data_dir
                   for f in Path(os.path.abspath(d)).rglob("coverage.dat"))
    if not files:
        sys.stderr.write(f"COVERAGE FAILED: {args.name}: no coverage.dat found\n")
        return 1

    points: dict[tuple, int] = {}
    for data in files:
        read_points(data, sources, points)
    if not points:
        sys.stderr.write(f"COVERAGE FAILED: {args.name}: no point in its RTL\n")
        return 1

    result = {"name": args.name, "category": args.category, "kinds": {}}
    for kind in KINDS.values():
        counts = [c for p, c in points.items() if p[0] == kind]
        hit = sum(1 for c in counts if c)
        result["kinds"][kind] = {"hit": hit, "total": len(counts),
                                 "percent": percent(hit, len(counts))}

    report_dir = Path(os.path.abspath(args.report_dir))
    report_dir.mkdir(parents=True, exist_ok=True)
    (report_dir / f"{args.name}.json").write_text(
        json.dumps(result, indent=2) + "\n", encoding="utf-8")

    missed = sorted(p for p, c in points.items() if not c)
    lines = [f"# Code coverage: {args.name} ({len(files)} data files)", ""]
    for kind, row in result["kinds"].items():
        lines.append(f"{kind:7} {row['hit']:6} / {row['total']:<6} {row['percent']}%")
    lines += ["", "# Points never hit", ""]
    lines += [f"{Path(p[1]).name}:{p[2]}: {p[0]}: {p[4]}" for p in missed]
    (report_dir / f"{args.name}.txt").write_text("\n".join(lines) + "\n",
                                                 encoding="utf-8")

    row = result["kinds"]
    print(f"COVERAGE: {args.name}: line {row['line']['percent']}%, "
          f"branch {row['branch']['percent']}%, "
          f"toggle {row['toggle']['percent']}%")
    return 0


def summary(args: argparse.Namespace) -> int:
    results = [json.loads(f.read_text(encoding="utf-8"))
               for f in sorted(Path(os.path.abspath(args.report_dir)).glob("*.json"))]
    if not results:
        sys.stderr.write("COVERAGE FAILED: no results; run ctest -L coverage\n")
        return 1

    print(f"{'IP':28} {'line':>7} {'branch':>7} {'toggle':>7}")
    totals = {kind: [0, 0] for kind in KINDS.values()}
    for result in sorted(results, key=lambda r: (r["category"], r["name"])):
        cells = []
        for kind, total in totals.items():
            row = result["kinds"][kind]
            total[0] += row["hit"]
            total[1] += row["total"]
            cells.append("-" if row["percent"] is None else f"{row['percent']:.1f}")
        print(f"{result['category'] + '/' + result['name']:28} "
              f"{cells[0]:>7} {cells[1]:>7} {cells[2]:>7}")
    cells = [f"{percent(hit, total) or 0.0:.1f}" for hit, total in totals.values()]
    print(f"{'all':28} {cells[0]:>7} {cells[1]:>7} {cells[2]:>7}")
    return 0


if __name__ == "__main__":
    options = parse_args()
    sys.exit(report(options) if options.command == "report" else summary(options))
