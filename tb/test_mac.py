"""mac (multiply-accumulate) modulu icin cocotb testbench'i.
Donanim (PIPELINE=1): her yukselen kenarda
    acc_reg <= clear ? 0 : (en ? acc_reg + a*b : acc_reg)
acc_out = acc_reg (kombinasyonel cikis).
"""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


A_WIDTH = 8
B_WIDTH = 8
ACC_WIDTH = 32
ACC_MASK = (1 << ACC_WIDTH) - 1


async def _reset(dut):
    dut.en.value = 0
    dut.clear.value = 0
    dut.a.value = 0
    dut.b.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")


@cocotb.test()
async def test_mac_accumulate(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    acc = 0  # referans model (32-bit sarmali)
    assert (int(dut.acc_out.value) & ACC_MASK) == 0, "reset sonrasi acc 0 degil"

    for _ in range(400):
        a = random.randint(-(1 << (A_WIDTH - 1)), (1 << (A_WIDTH - 1)) - 1)
        b = random.randint(-(1 << (B_WIDTH - 1)), (1 << (B_WIDTH - 1)) - 1)
        do_clear = random.random() < 0.1
        do_en = random.random() < 0.8

        dut.a.value = a
        dut.b.value = b
        dut.clear.value = int(do_clear)
        dut.en.value = int(do_en)

        await RisingEdge(dut.clk)   # girisler bu kenarda ornekleniyor

        if do_clear:
            acc = 0
        elif do_en:
            acc = (acc + a * b) & ACC_MASK

        await Timer(1, units="ns")  # kombinasyonel cikis otursun
        got = int(dut.acc_out.value) & ACC_MASK
        assert got == acc, \
            f"acc yanlis: en={int(do_en)} clear={int(do_clear)} a={a} b={b} -> " \
            f"beklenen {acc}, got {got}"
