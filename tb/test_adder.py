"""adder modulu icin cocotb testbench'i.
Rastgele vektorlerle a + b + cin = {cout, sum} dogrulanir.
"""
import random
import cocotb
from cocotb.triggers import Timer


WIDTH = 8
MASK = (1 << WIDTH) - 1


def _ref(a, b, cin):
    """Referans model: tam toplam, cout ve sum olarak ayrilmis."""
    full = a + b + cin
    return full & MASK, (full >> WIDTH) & 1


@cocotb.test()
async def test_adder_exhaustive_cin(dut):
    """Kucuk genislik icin birkac kenar durumu + rastgele vektorler."""
    edge = [0, 1, MASK, MASK - 1]
    cases = [(a, b, c) for a in edge for b in edge for c in (0, 1)]
    cases += [(random.randint(0, MASK), random.randint(0, MASK), random.randint(0, 1))
              for _ in range(500)]

    for a, b, cin in cases:
        dut.a.value = a
        dut.b.value = b
        dut.cin.value = cin
        await Timer(1, units="ns")

        exp_sum, exp_cout = _ref(a, b, cin)
        got_sum = int(dut.sum.value)
        got_cout = int(dut.cout.value)

        assert got_sum == exp_sum, \
            f"sum yanlis: a={a} b={b} cin={cin} -> got {got_sum}, beklenen {exp_sum}"
        assert got_cout == exp_cout, \
            f"cout yanlis: a={a} b={b} cin={cin} -> got {got_cout}, beklenen {exp_cout}"
