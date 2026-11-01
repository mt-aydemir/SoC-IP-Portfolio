#!/usr/bin/env python3
"""SystemVerilog testbench driver.

Compiles an IP together with its self-checking SystemVerilog testbench using
``verilator --binary`` and runs it. This is the Python-free smoke path: it
proves the IP works on a plain SystemVerilog simulator, independently of
cocotb.

A run passes only if the executable exits zero AND prints the agreed
"TEST PASSED" banner, so a testbench that silently ends early cannot be
mistaken for a success.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

PASS_BANNER = "TEST PASSED"
FAIL_BANNER = "TEST FAILED"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--verilator", default="verilator")
    p.add_argument("--top", required=True, help="testbench toplevel module")
    p.add_argument("--name", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--report", required=True)
    p.add_argument("--timescale", default="1ns/1ps")
    p.add_argument("--waves", action="store_true")
    p.add_argument("--wave-dir", default=None)
    p.add_argument("--param", action="append", default=[])
    p.add_argument("--sources", nargs="+", required=True,
                   help="RTL sources followed by the testbench source")
    return p.parse_args()


def main() -> int:
    args = parse_args()

    # Verilator is invoked with out_dir as its working directory, so every
    # path handed to it must be absolute: a relative --Mdir would be resolved
    # against out_dir itself and land one level deeper than intended.
    out_dir = Path(args.out_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    report = Path(args.report).resolve()
    report.parent.mkdir(parents=True, exist_ok=True)

    exe = out_dir / args.name
    build_cmd = [
        args.verilator,
        "--binary",
        "-sv",
        "--timing",
        "--assert",
        "-Wno-fatal",
        "--timescale", args.timescale,
        "--top-module", args.top,
        "--Mdir", str(out_dir),
        "-o", str(exe.resolve()),
    ]
    if args.waves:
        build_cmd += ["--trace", "--trace-structs"]
    for item in args.param:
        key, _, value = item.partition("=")
        build_cmd.append(f"-G{key.strip()}={value.strip()}")
    build_cmd += [str(Path(s).resolve()) for s in args.sources]

    build = subprocess.run(build_cmd, capture_output=True, text=True,
                           cwd=str(out_dir))
    log = ["# build\n", " ".join(build_cmd), "\n\n", build.stdout, build.stderr]

    if build.returncode != 0 or not exe.is_file():
        report.write_text("".join(log), encoding="utf-8")
        sys.stderr.write(build.stdout + build.stderr)
        sys.stderr.write(f"\nSVTB FAILED: {args.name} did not compile\n")
        return 1

    run_dir = out_dir / "run"
    run_dir.mkdir(exist_ok=True)
    run = subprocess.run([str(exe)], capture_output=True, text=True,
                         cwd=str(run_dir))
    log += ["\n# run\n", run.stdout, run.stderr]
    report.write_text("".join(log), encoding="utf-8")

    output = run.stdout + run.stderr
    if args.waves and args.wave_dir:
        wave_dir = Path(args.wave_dir)
        wave_dir.mkdir(parents=True, exist_ok=True)
        for produced in run_dir.glob("*.vcd"):
            produced.replace(wave_dir / f"{args.name}.svtb.vcd")

    if run.returncode != 0 or FAIL_BANNER in output or PASS_BANNER not in output:
        sys.stderr.write(output)
        sys.stderr.write(f"\nSVTB FAILED: {args.name}\n")
        return 1

    print(f"SVTB PASS: {args.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
