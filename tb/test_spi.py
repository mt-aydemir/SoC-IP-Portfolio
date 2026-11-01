"""spi_master modulu icin cocotb testbench'i.
Mode 0 (CPOL=0, CPHA=0), MSB-first, DATA_WIDTH=8, CLK_DIV=4.

BULUNAN HATA (belgeleniyor, kod degistirilmedi):
spi_master, 8 bitlik aktarimda yalnizca 7 SCLK yukselen kenari uretir.
Son ornekleme cevriminde hem `sclk <= ~sclk` hem `sclk <= CPOL` yazilir;
CPOL kazandigi icin 8. yukselen kenar olusmaz. Master kendi RX'ini FSM
olayindan ornekledigi icin ici dogru calisir, ama fiziksel hatta yalnizca
7 saat darbesi cikar -> gercek bir slave son biti kacirir.

test_spi_master_sclk_edges bu hatayi sabitler (8 bekler, 7 bulur -> FAIL).
Duzeltildiginde bu test yesile doner.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

DW = 8


async def _reset(dut):
    dut.start.value = 0
    dut.tx_data.value = 0
    dut.miso.value = 1
    dut.rst_n.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_spi_master_sclk_edges(dut):
    """Bir 8-bit aktarimda SCLK yukselen kenar sayisi == DATA_WIDTH olmali."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    dut.tx_data.value = 0xB7
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    rises = 0
    prev = int(dut.sclk.value)
    for _ in range(400):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        cur = int(dut.sclk.value)
        if prev == 0 and cur == 1:
            rises += 1
        prev = cur
        if int(dut.done.value) == 1:
            break

    assert rises == DW, (
        f"spi_master yalnizca {rises} SCLK yukselen kenari uretti, "
        f"{DW} olmali (son kenar bastiriliyor -- bkz. dosya basligi)"
    )


@cocotb.test(timeout_time=100, timeout_unit="us")
async def test_spi_master_mosi_first_bits(dut):
    """MOSI'den cikan ilk 7 bit tx_data'nin ust 7 biti olmali (MSB-first).
    (8. kenar olmadigi icin son bit dogrulanamiyor; kenar hatasindan bagimsiz
    olarak veri yolu/kaydirma dogru mu diye bakar.)"""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    tx = 0xB7  # 1011_0111
    dut.tx_data.value = tx
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    got = []
    prev = int(dut.sclk.value)
    for _ in range(400):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        cur = int(dut.sclk.value)
        if prev == 0 and cur == 1:          # yukselen kenarda MOSI ornekle
            got.append(int(dut.mosi.value))
        prev = cur
        if int(dut.done.value) == 1:
            break

    exp = [(tx >> (DW - 1 - i)) & 1 for i in range(len(got))]  # MSB-first
    assert got == exp, f"MOSI veri yolu yanlis: beklenen {exp}, got {got}"
