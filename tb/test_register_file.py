"""register_file modulu icin cocotb testbench'i.
Yazma: posedge clk, we ile regs[waddr]<=wdata (async reset ile temizlenir).
Okuma: KAYITLI -> re ise rdata<=regs[raddr] (bir kenar gecikme), degilse rdata<=0.
Ayni adrese ayni kenarda oku+yaz: NBA nedeniyle ESKI deger okunur.
"""
import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

WIDTH = 32
DEPTH = 8
WMASK = (1 << WIDTH) - 1


async def _reset(dut):
    dut.we.value = 0
    dut.re.value = 0
    dut.waddr.value = 0
    dut.raddr.value = 0
    dut.wdata.value = 0
    dut.reset.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.reset.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")


@cocotb.test()
async def test_regfile_write_read(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    model = [0] * DEPTH

    # Her adrese yaz
    for addr in range(DEPTH):
        val = random.randint(0, WMASK)
        model[addr] = val
        dut.waddr.value = addr
        dut.wdata.value = val
        dut.we.value = 1
        await RisingEdge(dut.clk)
        dut.we.value = 0
    await Timer(1, units="ns")

    # Her adresi oku (kayitli okuma: re ver, bir kenar sonra rdata hazir)
    for addr in range(DEPTH):
        dut.raddr.value = addr
        dut.re.value = 1
        await RisingEdge(dut.clk)   # bu kenarda rdata<=regs[addr]
        dut.re.value = 0
        await Timer(1, units="ns")
        got = int(dut.rdata.value) & WMASK
        assert got == model[addr], \
            f"okuma yanlis addr={addr}: beklenen {model[addr]}, got {got}"


@cocotb.test()
async def test_regfile_rdata_zero_when_not_re(dut):
    """re=0 iken rdata 0'a cekiliyor (tasarim boyle)."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    dut.waddr.value = 2
    dut.wdata.value = 0xDEADBEEF
    dut.we.value = 1
    await RisingEdge(dut.clk)
    dut.we.value = 0
    dut.re.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    assert int(dut.rdata.value) == 0, "re=0 iken rdata 0 olmali"
