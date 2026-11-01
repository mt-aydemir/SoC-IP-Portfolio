"""uart modulu icin cocotb testbench'i.
BAUD_DIV = CLK_FREQ/BAUD_RATE kucuk secilir (hiz icin), parametreyle gecilir.
8N1, LSB-first. reset aktif-yuksek.
"""
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

BAUD_DIV = 8
DATA_BITS = 8


async def _reset(dut):
    dut.tx_valid.value = 0
    dut.tx_data.value = 0
    dut.rxd.value = 1          # bosta hat yuksek
    dut.reset.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.reset.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")


async def _send_frame_to_rx(dut, byte):
    """rxd hattini surerek 8N1 bir cerceve gonderir (start,0..7,stop)."""
    bits = [0]                                   # start
    bits += [(byte >> i) & 1 for i in range(DATA_BITS)]  # LSB-first data
    bits += [1]                                  # stop
    for b in bits:
        dut.rxd.value = b
        for _ in range(BAUD_DIV):
            await RisingEdge(dut.clk)
    dut.rxd.value = 1


@cocotb.test()
async def test_uart_tx_serial(dut):
    """TX: txd hattindan cikan 8N1 cerceveyi geri cozup dogrula."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    test_byte = 0xA5
    assert int(dut.tx_ready.value) == 1, "reset sonrasi tx_ready olmali"
    dut.tx_data.value = test_byte
    dut.tx_valid.value = 1
    await RisingEdge(dut.clk)
    dut.tx_valid.value = 0

    # txd busy dusene kadar her clk ornekle
    samples = []
    for _ in range((DATA_BITS + 4) * BAUD_DIV + BAUD_DIV):
        await RisingEdge(dut.clk)
        await Timer(1, units="ns")
        samples.append(int(dut.txd.value))

    # start bitini (ilk 1->0 gecisi) bul, sonra bit ortalarindan ornekle
    try:
        start = samples.index(0)
    except ValueError:
        assert False, "txd hattinda start biti (0) hic gorulmedi"
    centers = [start + BAUD_DIV // 2 + k * BAUD_DIV for k in range(DATA_BITS + 2)]
    frame = [samples[c] for c in centers]

    assert frame[0] == 0, f"start biti 0 olmali, frame={frame}"
    data_bits = frame[1:1 + DATA_BITS]
    got = sum(b << i for i, b in enumerate(data_bits))
    assert frame[1 + DATA_BITS] == 1, f"stop biti 1 olmali, frame={frame}"
    assert got == test_byte, f"TX veri yanlis: gonderilen {hex(test_byte)}, cozulen {hex(got)} (frame={frame})"


@cocotb.test()
async def test_uart_rx(dut):
    """RX: rxd'ye bilinen bir bayt sur, rx_data/rx_valid dogru mu."""
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())
    await _reset(dut)

    test_byte = 0xA5
    got = None

    async def monitor():
        nonlocal got
        while True:
            await RisingEdge(dut.clk)
            if int(dut.rx_valid.value) == 1:
                got = int(dut.rx_data.value) & 0xFF
                return

    mon = cocotb.start_soon(monitor())
    await _send_frame_to_rx(dut, test_byte)
    # cercevenin bitmesini bekle
    for _ in range(3 * BAUD_DIV):
        await RisingEdge(dut.clk)

    assert got is not None, "rx_valid hic gelmedi"
    assert got == test_byte, f"RX veri yanlis: gonderilen {hex(test_byte)}, alinan {hex(got)}"
    mon.kill()
