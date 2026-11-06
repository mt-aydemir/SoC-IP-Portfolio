#!/usr/bin/env python3
"""UVM testbench driver (Verilator 5.052 or later, UVM 1800.2-2020 3.2).

Two modes, one CTest entry each:

  build   compile the UVM package, its DPI library, the RTL and the
          testbench into one executable with `verilator --binary`, once per
          configuration of the testbench's parameters
  run     run one UVM test in that executable

A run passes only if the log reports zero UVM_ERROR and zero UVM_FATAL and
the test printed "** UVM TEST PASSED **". The exit status alone is not
trusted: a UVM_FATAL ends the simulation with status zero under Verilator.

Constrained randomisation in Verilator calls an SMT solver at run time;
--solver names it and is passed through VERILATOR_SOLVER. The UVM package is
the flattened 2020-3.2 kit Verilator ships in its test suite, with its DPI
sources, found under --uvm-home.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

PASS_BANNER = "** UVM TEST PASSED **"
UVM_PKG = "uvm_pkg_all_v2020_3_2_dpi.svh"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="mode", required=True)

    b = sub.add_parser("build")
    b.add_argument("--verilator", required=True)
    b.add_argument("--uvm-home", required=True)
    b.add_argument("--top", required=True)
    b.add_argument("--out-dir", required=True)
    b.add_argument("--report", required=True)
    b.add_argument("--jobs", type=int, default=2)
    b.add_argument("--param", action="append", default=[])
    b.add_argument("--sources", nargs="+", required=True)

    r = sub.add_parser("run")
    r.add_argument("--exe", required=True)
    r.add_argument("--test", required=True)
    r.add_argument("--report", required=True)
    r.add_argument("--solver", default="z3")
    r.add_argument("--seed", type=int, default=1)
    return p.parse_args()


def build(args: argparse.Namespace) -> int:
    out_dir = Path(os.path.abspath(args.out_dir))
    out_dir.mkdir(parents=True, exist_ok=True)
    report = Path(os.path.abspath(args.report))
    report.parent.mkdir(parents=True, exist_ok=True)
    uvm = Path(os.path.abspath(args.uvm_home))

    cmd = [
        args.verilator, "--binary", "--vpi", "-j", str(args.jobs),
        # The UVM kit is large; -O0 keeps the C++ build within a few GB.
        "--CFLAGS", "-O0",
        # The testbench is not held to the RTL lint rules; the RTL is linted
        # in its own stage.
        "-Wno-fatal", "-Wno-lint", "-Wno-style",
        "--top-module", args.top,
        "--Mdir", str(out_dir / "obj_dir"), "-o", "tb",
        f"+incdir+{uvm}", str(uvm / UVM_PKG), str(uvm / "dpi" / "uvm_dpi.cc"),
    ]
    cmd += [f"-G{p}" for p in args.param]
    cmd += [str(Path(os.path.abspath(s))) for s in args.sources]

    proc = subprocess.run(cmd, cwd=out_dir, capture_output=True, text=True)
    log = proc.stdout + proc.stderr
    report.write_text(" ".join(cmd) + "\n\n" + log)
    errors = [l for l in log.splitlines() if l.startswith("%Error")]
    for line in errors[:20]:
        print(line)
    if proc.returncode != 0:
        print(f"UVM BUILD FAILED: {args.top}; log {report}")
        return 1
    print(f"uvm build {args.top}: {out_dir / 'obj_dir' / 'tb'}")
    return 0


def run(args: argparse.Namespace) -> int:
    report = Path(os.path.abspath(args.report))
    report.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["VERILATOR_SOLVER"] = f"{args.solver} --in"
    cmd = [args.exe, f"+UVM_TESTNAME={args.test}", "+UVM_NO_RELNOTES",
           f"+verilator+seed+{args.seed}"]
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    log = proc.stdout + proc.stderr
    report.write_text(log)

    counts = {sev: int(n) for sev, n in
              re.findall(r"^(UVM_ERROR|UVM_FATAL) :\s+(\d+)", log, re.M)}
    passed = PASS_BANNER in log
    for line in log.splitlines():
        if re.match(r"UVM_(ERROR|FATAL) \S", line) or "[TEST]" in line:
            print(line)
    ok = (proc.returncode == 0 and passed and counts.get("UVM_ERROR") == 0
          and counts.get("UVM_FATAL") == 0)
    print(f"uvm {args.test}: {'PASS' if ok else 'FAIL'} "
          f"(errors {counts.get('UVM_ERROR', '?')}, fatals {counts.get('UVM_FATAL', '?')}, "
          f"seed {args.seed})")
    if not ok:
        print(f"UVM TEST FAILED: {args.test}; log {report}")
    return 0 if ok else 1


def main() -> int:
    args = parse_args()
    return build(args) if args.mode == "build" else run(args)


if __name__ == "__main__":
    sys.exit(main())
