#!/usr/bin/env python3
"""cocotb simulation driver.

Builds one IP with Verilator and runs a cocotb test module against it.
Everything the run produces - the Verilated model, the VCD and the JUnit
results file - is written under the CMake binary directory. The source tree
is never touched.

Invoked by CMake (``add_ip(COCOTB_MODULES ...)``) and usable standalone:

    python scripts/run_cocotb.py \
        --top fifo_sync --name fifo_sync --module test_fifo_sync \
        --test-dir ip/memory/fifo_sync/cocotb \
        --build-dir build/ip/memory/fifo_sync/sim \
        --sources ip/memory/fifo_sync/rtl/fifo_sync.sv
"""
from __future__ import annotations

import argparse
import os
import shutil
import sys
from pathlib import Path

from cocotb.runner import get_runner

# The lint stage is the quality gate for warnings (run_lint.py, -Wall, no
# waivers). During the simulation build Verilator additionally instruments the
# design for VPI access, which can surface warnings that say nothing about RTL
# quality, so warnings are non-fatal here.
BUILD_ARGS = [
    "-Wno-fatal",
    "--assert",          # evaluate SystemVerilog assertions during simulation
    "--trace-structs",
]

WAVE_SUFFIXES = (".vcd", ".fst")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--top", required=True, help="HDL toplevel module")
    p.add_argument("--name", required=True, help="IP name (used in messages)")
    p.add_argument("--module", required=True, help="cocotb test module")
    p.add_argument("--test-dir", required=True, help="directory holding the test module")
    p.add_argument("--build-dir", required=True)
    p.add_argument("--wave-dir", default=None)
    p.add_argument("--results", default=None, help="destination for the JUnit XML")
    p.add_argument("--timescale", default="1ns/1ps")
    p.add_argument("--verilator", default=None)
    p.add_argument("--simulator", default="verilator")
    p.add_argument("--waves", action="store_true")
    p.add_argument("--coverage", action="store_true",
                   help="instrument the build; the run leaves coverage.dat")
    p.add_argument("--testcase", default=None, help="run a single testcase")
    p.add_argument("--seed", default=None, help="random seed for reproducible runs")
    p.add_argument("--param", action="append", default=[],
                   help="NAME=VALUE elaboration parameter override")
    p.add_argument("--sources", nargs="+", required=True)
    return p.parse_args()


def split_timescale(ts: str) -> tuple[str, str]:
    unit, _, precision = ts.partition("/")
    return unit.strip(), (precision.strip() or unit.strip())


def coerce(value: str) -> object:
    """Turn a command-line parameter value into int where possible."""
    text = value.strip()
    try:
        return int(text, 0)
    except ValueError:
        return text


def summarise_results(results_xml: Path) -> tuple[int, int, int]:
    """Return (passed, failed, skipped) from a cocotb JUnit results file.

    A missing or empty file counts as zero tests, which the caller treats as
    a failure - a run that produced no results did not verify anything.
    """
    if not results_xml.is_file():
        return (0, 0, 0)

    import xml.etree.ElementTree as ET  # stdlib, imported lazily

    try:
        root = ET.parse(results_xml).getroot()
    except ET.ParseError:
        return (0, 1, 0)

    passed = failed = skipped = 0
    for case in root.iter("testcase"):
        children = {child.tag for child in case}
        if "failure" in children or "error" in children:
            failed += 1
        elif "skipped" in children:
            skipped += 1
        else:
            passed += 1
    return (passed, failed, skipped)


def collect_waves(build_dir: Path, wave_dir: Path, name: str, module: str) -> list[Path]:
    wave_dir.mkdir(parents=True, exist_ok=True)
    moved = []
    for path in sorted(build_dir.rglob("*")):
        if path.suffix in WAVE_SUFFIXES and path.is_file():
            dest = wave_dir / f"{name}.{module}{path.suffix}"
            shutil.copy2(path, dest)
            moved.append(dest)
    return moved


def main() -> int:
    args = parse_args()

    build_dir = Path(os.path.abspath(args.build_dir))
    build_dir.mkdir(parents=True, exist_ok=True)
    src_test_dir = Path(os.path.abspath(args.test_dir))
    if not src_test_dir.is_dir():
        sys.stderr.write(f"test directory not found: {src_test_dir}\n")
        return 1

    # The simulator runs with test_dir as its working directory and writes the
    # results file there, so it must be inside the build tree. The IP's cocotb
    # directory is made importable through PYTHONPATH instead.
    run_dir = build_dir / "run"
    run_dir.mkdir(parents=True, exist_ok=True)

    sources = [str(Path(os.path.abspath(s))) for s in args.sources]
    parameters = {}
    for item in args.param:
        key, _, value = item.partition("=")
        parameters[key.strip()] = coerce(value)

    if args.verilator:
        # cocotb's runner finds Verilator on PATH and needs no VERILATOR_ROOT.
        # Left unset, every Verilator - packaged or built from source - finds
        # its own files; an empty value sends a source-built one looking for
        # /verilator_bin.
        if not os.environ.get("VERILATOR_ROOT"):
            os.environ.pop("VERILATOR_ROOT", None)
        os.environ["PATH"] = os.pathsep.join(
            [str(Path(args.verilator).parent), os.environ.get("PATH", "")])

    # Shared verification library (BFMs, scoreboards, helpers) plus the IP's
    # own cocotb directory must be importable by the test module inside the
    # simulator process. cocotb's runner derives the simulator's PYTHONPATH
    # from this process's sys.path and overwrites anything passed through
    # extra_env, so the paths are injected into sys.path here.
    # The IP's cocotb directory is importable, which would otherwise leave a
    # __pycache__ behind inside the source tree. Bytecode caching buys nothing
    # here and the portfolio rule is that nothing generated lands in source.
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    sys.dont_write_bytecode = True

    verif_lib = Path(os.path.abspath(__file__)).parent.parent / "verification" / "lib"
    for extra_path in (str(verif_lib), str(src_test_dir)):
        if extra_path not in sys.path:
            sys.path.insert(0, extra_path)
    os.environ["PYTHONPATH"] = os.pathsep.join(
        p for p in (str(src_test_dir), str(verif_lib),
                    os.environ.get("PYTHONPATH", "")) if p)

    runner = get_runner(args.simulator)

    runner.build(
        verilog_sources=sources,
        hdl_toplevel=args.top,
        build_dir=str(build_dir),
        always=True,
        build_args=BUILD_ARGS + (["--coverage"] if args.coverage else []),
        parameters=parameters,
        timescale=split_timescale(args.timescale),
        waves=args.waves,
    )

    # Elaboration parameters are exported into the environment as
    # SOCIP_PARAM_<NAME>. Reading a parameter through the simulator handle is
    # not portable across back ends, so tests use socip.params.get_param()
    # which reads these variables and falls back to the RTL default.
    extra_env = {"COCOTB_RESOLVE_X": "ZEROS"}
    for key, value in parameters.items():
        extra_env[f"SOCIP_PARAM_{key.upper()}"] = str(value)
    if args.seed is not None:
        extra_env["COCOTB_RANDOM_SEED"] = str(args.seed)

    results_name = f"{args.name}.{args.module}.results.xml"
    produced = runner.test(
        hdl_toplevel=args.top,
        test_module=args.module,
        test_dir=str(run_dir),
        build_dir=str(build_dir),
        results_xml=results_name,
        testcase=args.testcase,
        parameters=parameters,
        extra_env=extra_env,
        waves=args.waves,
        timescale=split_timescale(args.timescale),
    )

    if args.results:
        dest = Path(args.results)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if Path(produced).is_file():
            shutil.copy2(produced, dest)

    if args.waves and args.wave_dir:
        for wave in collect_waves(build_dir, Path(args.wave_dir), args.name, args.module):
            print(f"wave: {wave}")

    # The cocotb runner does not raise on a failing regression, and it also
    # returns cleanly when the test module could not be imported at all. Both
    # must fail the build, so the JUnit results are inspected directly.
    passed, failed, skipped = summarise_results(Path(produced))
    if failed or passed == 0:
        reason = (f"{failed} test(s) failed"
                  if failed else "no tests ran (module import failure?)")
        sys.stderr.write(
            f"\nSIM FAILED: {args.name}:{args.module} - {reason}\n"
            f"  results: {produced}\n")
        return 1

    extra = f", {skipped} skipped" if skipped else ""
    print(f"SIM PASS: {args.name}:{args.module}  ({passed} passed{extra})")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 - surface the tool error to CTest
        sys.stderr.write(f"SIM FAILED: {exc}\n")
        sys.exit(1)
