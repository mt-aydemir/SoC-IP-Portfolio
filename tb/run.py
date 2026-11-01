"""Verilator + cocotb kosucusu.
Kullanim: python run.py <toplevel> <test_modulu> <kaynak1.sv> [kaynak2.sv ...]
Ornek:    python run.py adder test_adder ../arithmetic/adder.sv
"""
import sys
from pathlib import Path
from cocotb.runner import get_runner

toplevel = sys.argv[1]
test_module = sys.argv[2]
rest = sys.argv[3:]
sources = [Path(s).resolve() for s in rest if "=" not in s]
parameters = {}
for tok in rest:
    if "=" in tok:
        k, v = tok.split("=", 1)
        parameters[k] = v

runner = get_runner("verilator")
runner.build(
    verilog_sources=sources,
    hdl_toplevel=toplevel,
    parameters=parameters,
    build_args=["--trace", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC"],
    always=True,
)
runner.test(
    hdl_toplevel=toplevel,
    test_module=test_module,
    test_dir=Path(__file__).parent,
)
