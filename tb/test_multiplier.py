"""multiplier modulu: product = a * b (isaretsiz, 2*WIDTH bit)."""
import random
import cocotb
from cocotb.triggers import Timer

WIDTH = 8
MASK = (1 << WIDTH) - 1


@cocotb.test()
async def test_multiplier(dut):
    edge = [0, 1, MASK, MASK - 1]
    cases = [(a, b) for a in edge for b in edge]
    cases += [(random.randint(0, MASK), random.randint(0, MASK)) for _ in range(500)]
    for a, b in cases:
        dut.a.value = a
        dut.b.value = b
        await Timer(1, units="ns")
        got = int(dut.product.value)
        assert got == a * b, f"product yanlis: {a}*{b} -> got {got}, beklenen {a*b}"
