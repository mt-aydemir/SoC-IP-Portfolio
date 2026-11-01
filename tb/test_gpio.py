"""gpio modulu icin cocotb testbench'i.
wr_en + wr_dir=1 -> dir_reg<=wr_data ; wr_dir=0 -> data_reg<=wr_data
pin_out = data_reg & dir_reg ; pin_oe = dir_reg
NOT: pin_in bu tasarimda hic kullanilmiyor (giris okuma yok) -- bilerek test edilmiyor.
"""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

WIDTH = 8
MASK = (1 << WIDTH) - 1


async def _write(dut, data, is_dir):
    dut.wr_data.value = data
    dut.wr_dir.value = int(is_dir)
    dut.wr_en.value = 1
    await RisingEdge(dut.clk)
    dut.wr_en.value = 0
    await Timer(1, units="ns")


@cocotb.test()
async def test_gpio_dir_and_out(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    dut.wr_en.value = 0
    dut.wr_dir.value = 0
    dut.wr_data.value = 0
    dut.pin_in.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")

    assert int(dut.pin_oe.value) == 0, "reset sonrasi pin_oe 0 olmali"
    assert int(dut.pin_out.value) == 0, "reset sonrasi pin_out 0 olmali"

    for _ in range(200):
        d = random.randint(0, MASK)
        direction = random.randint(0, MASK)
        await _write(dut, d, is_dir=False)      # data_reg <= d
        await _write(dut, direction, is_dir=True)  # dir_reg <= direction

        exp_out = d & direction
        assert int(dut.pin_oe.value) == direction, \
            f"pin_oe yanlis: beklenen {direction}, got {int(dut.pin_oe.value)}"
        assert int(dut.pin_out.value) == exp_out, \
            f"pin_out yanlis: data={d} dir={direction} -> beklenen {exp_out}, got {int(dut.pin_out.value)}"
