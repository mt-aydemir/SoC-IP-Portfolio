"""Cocotb regression for spi_master.

Coverage
    directed   the reset state; all four modes in both bit orders; the
               fastest SCLK (clk_div = 1) and an odd divider; multi-word
               frames with chip select held across host gaps; back-to-back
               frames
    randomised random mode, bit order, divider, frame length, inter-word gaps
               and data, every word checked in both directions
    regression every word is exactly 2 * DATA_WIDTH SCLK edges (the previous
               implementation dropped the last one, so a real slave missed
               the final bit), SCLK idles at cpol whenever cs_n is high, and
               mosi is stable for a full half period before every sampling
               edge

The checker is an SPI slave written from the mode definitions in the RTL
header. It samples the bus on every clock, so it also measures the timing:
the half period between edges, the setup of mosi before each sampling edge,
the cs_n high time between frames and the edge count of every frame.
"""
from __future__ import annotations

from collections import deque

import cocotb
from cocotb.triggers import NextTimeStep, ReadOnly, RisingEdge

from socip import ClockDomain, RandomStream, assert_eq, describe, get_param

DATA_WIDTH = get_param("DATA_WIDTH", 8)
DIV_WIDTH = get_param("DIV_WIDTH", 8)

CLK_PERIOD_NS = 10.0
MASK = (1 << DATA_WIDTH) - 1


def word_bits(word: int, lsb_first: int) -> list[int]:
    order = range(DATA_WIDTH) if lsb_first else reversed(range(DATA_WIDTH))
    return [(word >> i) & 1 for i in order]


def bits_word(bits: list[int], lsb_first: int) -> int:
    if not lsb_first:
        bits = list(reversed(bits))
    return sum(b << i for i, b in enumerate(bits))


class SpiSlave:
    """A mode-aware SPI slave and bus timing checker, sampled every clock."""

    def __init__(self, dut, rng: RandomStream) -> None:
        self.dut = dut
        self.rng = rng
        self.cpol = self.cpha = self.lsb = 0
        self.div = 1
        self.responses: deque[int] = deque()   # words the slave will send
        self.sent: list[int] = []              # words fully clocked out
        self._loaded: list[int] = []           # words loaded this frame
        self.received: list[int] = []          # words the slave received
        self.frames: list[int] = []            # words per completed frame
        self.errors: list[str] = []
        self._task = cocotb.start_soon(self._run())

    def configure(self, cpol: int, cpha: int, lsb: int, div: int) -> None:
        self.cpol, self.cpha, self.lsb, self.div = cpol, cpha, lsb, div

    def stop(self) -> None:
        self._task.kill()

    def _error(self, cycle: int, message: str) -> None:
        self.errors.append(f"cycle {cycle}: {message}")

    def _next_word(self) -> int:
        word = self.responses.popleft() if self.responses else \
            self.rng.uint(DATA_WIDTH)
        # With cpha = 0 a slave loads the next word on the last trailing edge
        # of the current one, before it knows whether the frame continues; a
        # word only counts as sent once the master has clocked all of it.
        self._loaded.append(word)
        return word

    async def _run(self) -> None:
        dut = self.dut
        cycle = 0
        prev_sclk = prev_cs = prev_mosi = None
        mosi_changed = 0
        cs_rise = -10**9
        cs_rise_div = 1      # the half period in force when cs_n rose
        last_edge = 0
        frame_edges = 0
        frame_words = 0
        tx_stream: deque[int] = deque()
        rx_bits: list[int] = []

        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            cycle += 1
            sclk = int(dut.sclk.value)
            cs = int(dut.cs_n.value)
            mosi = int(dut.mosi.value)
            drive = None

            if prev_cs is None:                                 # first sample
                prev_sclk, prev_cs, prev_mosi = sclk, cs, mosi
                continue

            if mosi != prev_mosi:
                mosi_changed = cycle

            if prev_cs and not cs:                              # frame start
                if cycle - cs_rise < cs_rise_div:
                    self._error(cycle, f"cs_n high for {cycle - cs_rise} "
                                f"cycles, under a half period of "
                                f"{cs_rise_div}")
                if sclk != self.cpol:
                    self._error(cycle, "SCLK not idle when cs_n fell")
                frame_edges = frame_words = 0
                self._loaded = []
                rx_bits = []
                tx_stream = deque()
                if self.cpha == 0:
                    tx_stream.extend(word_bits(self._next_word(), self.lsb))
                    drive = tx_stream.popleft()

            elif not prev_cs and cs:                            # frame end
                cs_rise = cycle
                cs_rise_div = self.div
                if frame_edges != 2 * DATA_WIDTH * frame_words or rx_bits:
                    self._error(cycle, f"frame of {frame_words} words had "
                                f"{frame_edges} SCLK edges and "
                                f"{len(rx_bits)} stray bits")
                self.frames.append(frame_words)
                self.sent.extend(self._loaded[:frame_words])

            elif not cs and sclk != prev_sclk:                  # SCLK edge
                frame_edges += 1
                first_of_word = (frame_edges - 1) % (2 * DATA_WIDTH) == 0
                if not first_of_word and cycle - last_edge != self.div:
                    self._error(cycle, f"half period {cycle - last_edge} "
                                f"cycles, expected {self.div}")
                last_edge = cycle
                leading = sclk != self.cpol
                if leading != bool(self.cpha):                  # sample edge
                    if cycle - mosi_changed < self.div:
                        self._error(cycle, "mosi changed "
                                    f"{cycle - mosi_changed} cycles before "
                                    "the sampling edge")
                    rx_bits.append(mosi)
                    if len(rx_bits) == DATA_WIDTH:
                        self.received.append(bits_word(rx_bits, self.lsb))
                        rx_bits = []
                        frame_words += 1
                else:                                           # shift edge
                    if not tx_stream:
                        tx_stream.extend(word_bits(self._next_word(),
                                                   self.lsb))
                    drive = tx_stream.popleft()

            elif cs and sclk != prev_sclk and sclk != self.cpol:
                # Moving to a new cpol a cycle after it changed is expected;
                # moving away from cpol is not.
                self._error(cycle, "SCLK moved away from cpol while "
                            "deselected")

            prev_sclk, prev_cs, prev_mosi = sclk, cs, mosi
            if drive is not None:
                await NextTimeStep()
                dut.miso.value = drive


class Master:
    """Drives the host side: configuration, words, and received words."""

    def __init__(self, dut) -> None:
        self.dut = dut
        self.received: list[int] = []
        cocotb.start_soon(self._collect())

    async def _collect(self) -> None:
        while True:
            await RisingEdge(self.dut.clk)
            await ReadOnly()
            if int(self.dut.m_valid.value):
                self.received.append(int(self.dut.m_data.value))

    async def idle(self) -> None:
        while True:
            await ReadOnly()
            if not int(self.dut.busy.value):
                break
            await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)

    async def configure(self, slave: SpiSlave, cpol: int, cpha: int,
                        lsb: int, div: int) -> None:
        await self.idle()
        self.dut.cpol.value = cpol
        self.dut.cpha.value = cpha
        self.dut.lsb_first.value = lsb
        self.dut.clk_div.value = div
        slave.configure(cpol, cpha, lsb, div)
        # Let SCLK settle to the new idle level before the next frame.
        for _ in range(2):
            await RisingEdge(self.dut.clk)

    async def send(self, word: int, last: int) -> None:
        dut = self.dut
        dut.s_data.value = word & MASK
        dut.s_last.value = last
        dut.s_valid.value = 1
        while True:
            await ReadOnly()
            if int(dut.s_ready.value):
                break
            await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)
        dut.s_valid.value = 0

    async def frame(self, words: list[int], gaps: list[int] | None = None) -> None:
        for i, word in enumerate(words):
            await self.send(word, int(i == len(words) - 1))
            if gaps:
                for _ in range(gaps[i]):
                    await RisingEdge(self.dut.clk)
        await self.idle()


async def setup(dut, rng_name: str) -> tuple[Master, SpiSlave, RandomStream]:
    rng = RandomStream(rng_name)
    dut._log.info("spi_master: DATA_WIDTH=%d DIV_WIDTH=%d, seed %d, %s",
                  DATA_WIDTH, DIV_WIDTH, rng.seed, describe())
    dut.cpol.value = 0
    dut.cpha.value = 0
    dut.lsb_first.value = 0
    dut.clk_div.value = 2
    dut.s_valid.value = 0
    dut.s_data.value = 0
    dut.s_last.value = 0
    dut.miso.value = 0
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    await domain.reset()
    slave = SpiSlave(dut, rng)
    slave.configure(0, 0, 0, 2)
    return Master(dut), slave, rng


async def exchange(master: Master, slave: SpiSlave, words: list[int],
                   gaps: list[int] | None = None) -> None:
    """Send one frame and check both directions and the bus timing."""
    responses = [slave.rng.uint(DATA_WIDTH) for _ in words]
    slave.responses.extend(responses)
    sent_before = len(slave.sent)
    m_before = len(master.received)
    s_before = len(slave.received)
    await master.frame(words, gaps)
    for _ in range(4):
        await RisingEdge(master.dut.clk)
    await NextTimeStep()
    assert not slave.errors, "; ".join(slave.errors[:3])
    assert slave.received[s_before:] == [w & MASK for w in words], \
        f"slave received {slave.received[s_before:]}, sent {words}"
    got = master.received[m_before:]
    want = slave.sent[sent_before:sent_before + len(words)]
    assert got == want, f"master received {got}, slave sent {want}"
    assert_eq(slave.frames[-1], len(words), "words in the cs_n frame")


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: deselected, SCLK idle low, ready, not busy."""
    await setup(dut, "spi_reset")
    await ReadOnly()
    assert_eq(int(dut.cs_n.value), 1, "cs_n high")
    assert_eq(int(dut.sclk.value), 0, "SCLK at cpol")
    assert_eq(int(dut.s_ready.value), 1, "ready")
    assert_eq(int(dut.busy.value), 0, "not busy")
    assert_eq(int(dut.m_valid.value), 0, "nothing received")


@cocotb.test()
async def test_all_modes(dut) -> None:
    """Directed: every mode in both bit orders, corner words."""
    master, slave, _rng = await setup(dut, "spi_modes")
    words = [0x00, MASK, 0x55 & MASK, 0xAA & MASK, 0x01, 1 << (DATA_WIDTH - 1)]
    for cpol in (0, 1):
        for cpha in (0, 1):
            for lsb in (0, 1):
                await master.configure(slave, cpol, cpha, lsb, 2)
                await exchange(master, slave, words)


@cocotb.test()
async def test_divider_extremes(dut) -> None:
    """Directed: the fastest SCLK and an odd divider, in two modes."""
    master, slave, _rng = await setup(dut, "spi_div")
    for div in (1, 5, (1 << DIV_WIDTH) - 1):
        for cpha in (0, 1):
            await master.configure(slave, 1, cpha, 0, div)
            await exchange(master, slave, [0xC3 & MASK, 0x3C & MASK])


@cocotb.test()
async def test_frame_with_gaps(dut) -> None:
    """Directed: cs_n stays low across host gaps inside a frame."""
    master, slave, _rng = await setup(dut, "spi_gaps")
    for cpha in (0, 1):
        await master.configure(slave, 0, cpha, 0, 3)
        await exchange(master, slave, [0x9F & MASK, 0x00, 0x00, 0x00],
                       gaps=[0, 25, 3, 0])


@cocotb.test()
async def test_back_to_back_frames(dut) -> None:
    """Regression: consecutive single-word frames keep the cs_n high time."""
    master, slave, _rng = await setup(dut, "spi_b2b")
    await master.configure(slave, 0, 0, 0, 4)
    for word in range(8):
        await exchange(master, slave, [(word * 29) & MASK])


# ---------------------------------------------------------------------------
# Randomised
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_frames(dut) -> None:
    """Randomised: mode, order, divider, frame length, gaps and data."""
    master, slave, rng = await setup(dut, "spi_random")
    for _ in range(40):
        await master.configure(slave, rng.between(0, 1), rng.between(0, 1),
                               rng.between(0, 1), rng.between(1, 6))
        length = rng.between(1, 5)
        words = [rng.corner_uint(DATA_WIDTH) for _ in range(length)]
        gaps = [rng.between(0, 12) if rng.boolean(0.4) else 0
                for _ in range(length)]
        await exchange(master, slave, words, gaps)
