#!/usr/bin/env python3
"""Formal proof driver (SymbiYosys).

Writes a two-task .sby file for one IP's property wrapper and runs it:

  prove   k-induction with smtbmc: every assertion holds in every reachable
          state, under the wrapper's assumptions
  cover   every cover statement is reached within the depth, which is what
          shows that the assumptions have not ruled out the behaviour the
          assertions are about - a proof under contradictory assumptions is
          vacuous, and an unreached cover is how that shows up

A run passes only if both tasks report PASS. The RTL is read with SYNTHESIS
and FORMAL defined: SYNTHESIS keeps out the simulation-only assertions, whose
SVA constructs the free Yosys frontend does not parse, and FORMAL is there
for wrappers that want it.

PROBES
  k-induction needs properties that pin down a design's internal state, and
  the free Yosys frontend has no hierarchical references. A wrapper declares
  an undriven (* keep *) wire for each internal signal it needs and names
  its source in a pragma line,

      // formal-connect: f_state = dut.state

  and this script flattens the design and joins the two with `connect -set`
  before the proof. The RTL itself carries no formal code.

MULTICLOCK
  With --multiclock the clocks are ordinary free inputs and every solver
  step may change any input, clocks included, so every ordering of edges
  and data changes across domains is explored. A wrapper that needs a
  per-step history declares the solver's clock as (* gclk *) reg gclk.

When SymbiYosys is the YoWASP build, the Yosys, smtbmc and witness programs
it starts are the YoWASP ones beside it; their plain names are not installed
by a no-root setup.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--sby", default="sby")
    p.add_argument("--solver", default="z3")
    p.add_argument("--top", required=True, help="property wrapper module")
    p.add_argument("--name", required=True)
    p.add_argument("--depth", type=int, default=20)
    p.add_argument("--multiclock", action="store_true",
                   help="clocks are free inputs; one solver step per input change")
    p.add_argument("--out-dir", required=True)
    p.add_argument("--report", required=True)
    p.add_argument("--param", action="append", default=[])
    p.add_argument("--sources", nargs="+", required=True)
    return p.parse_args()


PROBE = re.compile(r"//\s*formal-connect:\s*(\S+)\s*=\s*(\S+)")


def probe_pragmas(sources: list[str]) -> list[tuple[str, str]]:
    return [m.groups() for s in sources for m in PROBE.finditer(Path(s).read_text())]


def sby_text(args: argparse.Namespace) -> str:
    reads = "\n".join(f"read_verilog -formal -sv -DSYNTHESIS -DFORMAL {Path(os.path.abspath(s))}"
                      for s in args.sources)
    params = "\n".join(f"chparam -set {k} {v} {args.top}"
                       for k, v in (p.split("=", 1) for p in args.param))
    probes = "\n".join(f"connect -set {lhs} {rhs}" for lhs, rhs in probe_pragmas(args.sources))
    return f"""[tasks]
prove
cover

[options]
prove: mode prove
cover: mode cover
depth {args.depth}
{"multiclock on" if args.multiclock else ""}

[engines]
smtbmc {args.solver}

[script]
{reads}
{params}
prep -flatten -top {args.top}
memory_map
opt_clean
{probes}
"""


def tool_env(sby: str) -> dict[str, str]:
    env = dict(os.environ)
    path = Path(shutil.which(sby) or sby)
    if path.name.startswith("yowasp-"):
        for var, prog in (("YOSYS", "yowasp-yosys"), ("SMTBMC", "yowasp-yosys-smtbmc"),
                          ("WITNESS", "yowasp-yosys-witness")):
            sibling = path.parent / prog
            env.setdefault(var, str(sibling) if sibling.exists() else prog)
    # The solver lives beside the interpreter in a venv setup.
    env["PATH"] = f"{Path(sys.executable).parent}{os.pathsep}{env.get('PATH', '')}"
    return env


def main() -> int:
    args = parse_args()
    out_dir = Path(os.path.abspath(args.out_dir))
    out_dir.mkdir(parents=True, exist_ok=True)
    report = Path(os.path.abspath(args.report))
    report.parent.mkdir(parents=True, exist_ok=True)

    sby_file = out_dir / f"{args.name}.sby"
    sby_file.write_text(sby_text(args))

    proc = subprocess.run([args.sby, "-f", sby_file.name], cwd=out_dir, env=tool_env(args.sby),
                          capture_output=True, text=True)
    log = proc.stdout + proc.stderr
    report.write_text(log)

    status = dict(re.findall(rf"\[{re.escape(args.name)}_(prove|cover)\] DONE \((\w+)", log))
    interesting = re.compile(r"summary: +(failed|reached|unreached|  )|Assert failed|"
                             r"Cover .*reached|ERROR|Status:|trace")
    for line in log.splitlines():
        if interesting.search(line):
            print(line)
    ok = status.get("prove") == "PASS" and status.get("cover") == "PASS"
    print(f"formal {args.name}: prove {status.get('prove', 'ERROR')}, "
          f"cover {status.get('cover', 'ERROR')} (depth {args.depth}, {args.solver})")
    if not ok:
        print(f"FORMAL FAILED: {args.name}; log {report}, traces under {out_dir}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
