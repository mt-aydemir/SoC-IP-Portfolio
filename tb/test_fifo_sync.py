"""fifo_sync modulu icin cocotb testbench'i.
Senkron FIFO: wr_en/rd_en, full/empty, FIFO (ilk giren ilk cikar) sirasi.
Reset senkron (posedge clk icinde !rst_n).
rd_data kayitli: rd_en ile okunan veri bir sonraki kenarda cikista.
"""
import random
from collections import deque
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


DATA_WIDTH = 8
DEPTH = 16
DMASK = (1 << DATA_WIDTH) - 1


async def _reset(dut):
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    dut.wr_data.value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")


@cocotb.test()
async def test_fifo_fill_drain(dut):
    """Doldur -> full kontrol -> bosalt -> sira ve empty kontrol."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    assert int(dut.empty.value) == 1, "reset sonrasi empty olmali"
    assert int(dut.full.value) == 0, "reset sonrasi full olmamali"

    data = [random.randint(0, DMASK) for _ in range(DEPTH)]

    # Doldur
    for d in data:
        assert int(dut.full.value) == 0, "doluluktan once full gorundu"
        dut.wr_data.value = d
        dut.wr_en.value = 1
        await RisingEdge(dut.clk)
        dut.wr_en.value = 0
        await Timer(1, units="ns")

    assert int(dut.full.value) == 1, f"{DEPTH} yazimdan sonra full olmali"
    assert int(dut.empty.value) == 0, "dolu FIFO empty gorunemez"

    # Bosalt ve sirayi dogrula
    out = []
    for _ in range(DEPTH):
        dut.rd_en.value = 1
        await RisingEdge(dut.clk)   # bu kenarda rd_data guncellenir
        dut.rd_en.value = 0
        await Timer(1, units="ns")
        out.append(int(dut.rd_data.value) & DMASK)

    assert int(dut.empty.value) == 1, "bosaltma sonrasi empty olmali"
    assert out == data, f"FIFO sirasi bozuk:\n beklenen {data}\n got      {out}"


@cocotb.test()
async def test_fifo_random(dut):
    """Rastgele yaz/oku, referans kuyrukla karsilastir."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    model = deque()
    for _ in range(1000):
        can_wr = int(dut.full.value) == 0
        can_rd = int(dut.empty.value) == 0
        do_wr = can_wr and random.random() < 0.5
        do_rd = can_rd and random.random() < 0.5

        wd = random.randint(0, DMASK)
        dut.wr_en.value = int(do_wr)
        dut.rd_en.value = int(do_rd)
        dut.wr_data.value = wd

        expected = model[0] if do_rd else None
        await RisingEdge(dut.clk)
        dut.wr_en.value = 0
        dut.rd_en.value = 0
        await Timer(1, units="ns")

        if do_rd:
            got = int(dut.rd_data.value) & DMASK
            assert got == expected, f"okuma yanlis: beklenen {expected}, got {got}"
            model.popleft()
        if do_wr:
            model.append(wd)
