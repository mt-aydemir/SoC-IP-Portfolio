#!/usr/bin/env python3
"""Verilator lint driver.

Runs ``verilator --lint-only`` over one IP's RTL with the project-wide warning
policy, writes the log under the build tree and fails on any diagnostic.

The project treats lint cleanliness as a hard gate: an IP that does not lint
clean cannot be simulated, synthesised or released.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path

# Warning set enabled for every IP. -Wall in Verilator 5 already implies most
# of these; they are listed explicitly so the policy is visible and stable
# across Verilator releases.
WARNING_POLICY = [
    "-Wall",
    "-Wno-fatal",  # collect every diagnostic, then decide below
]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--verilator", default="verilator")
    p.add_argument("--top", required=True)
    p.add_argument("--name", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--report", required=True)
    p.add_argument("--timescale", default="1ns/1ps")
    p.add_argument("--param", action="append", default=[],
                   help="NAME=VALUE elaboration parameter override")
    p.add_argument("--extra-arg", action="append", default=[],
                   help="additional raw Verilator argument")
    p.add_argument("--sources", nargs="+", required=True)
    return p.parse_args()


def main() -> int:
    args = parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    report = Path(args.report)
    report.parent.mkdir(parents=True, exist_ok=True)

    cmd = [
        args.verilator,
        "--lint-only",
        "-sv",
        "--timescale", args.timescale,
        "--top-module", args.top,
        "--Mdir", str(out_dir),
    ]
    cmd += WARNING_POLICY
    cmd += args.extra_arg
    for p in args.param:
        name, _, value = p.partition("=")
        # Verilator requires the value attached to the switch: -GNAME=VALUE.
        cmd.append(f"-G{name.strip()}={value.strip()}")
    cmd += [str(Path(os.path.abspath(s))) for s in args.sources]

    proc = subprocess.run(cmd, capture_output=True, text=True)
    output = proc.stdout + proc.stderr

    report.write_text(
        f"# verilator lint: {args.name} (top={args.top})\n"
        f"# command: {' '.join(cmd)}\n\n{output}",
        encoding="utf-8",
    )

    # Any %Error or %Warning is a failure. Verilator exits 0 with -Wno-fatal
    # even when warnings were emitted, so inspect the text as well.
    has_error = "%Error" in output
    has_warning = "%Warning" in output

    if output.strip():
        sys.stderr.write(output)

    if has_error or has_warning or proc.returncode != 0:
        sys.stderr.write(
            f"\nLINT FAILED: {args.name}  (see {report})\n")
        return 1

    print(f"LINT PASS: {args.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
