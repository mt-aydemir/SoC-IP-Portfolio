"""Cocotb regression for uart.

Coverage
    directed   the reset state; transmitted frames bit by bit with their
               exact timing; received characters; parity and framing errors;
               a break; a start-bit glitch; overrun; the minimum bit period
               and an odd one
    randomised full-duplex loopback with random words, random bit periods
               and random receive back-pressure
    regression the receiver tolerates a transmitter 3 % fast or slow, sampled
               asynchronously to the clock; a break produces exactly one
               character; back-to-back transmission keeps every bit period

The checkers work on the serial line, not on internal state. The transmit
monitor samples txd on every clock and requires each bit to hold its level
for exactly clks_per_bit cycles; the receive driver produces frames from
real-time delays that are not aligned to the clock. Expected frames are
built from the frame format in the RTL header.
"""
from __future__ import annotations

from collections import deque

import cocotb
from cocotb.triggers import NextTimeStep, ReadOnly, RisingEdge, Timer

from socip import ClockDomain, RandomStream, assert_eq, describe, get_param

DATA_BITS = get_param("DATA_BITS", 8)
PARITY = get_param("PARITY", 0)
STOP_BITS = get_param("STOP_BITS", 1)
DIV_WIDTH = get_param("DIV_WIDTH", 16)
SYNC_STAGES = get_param("SYNC_STAGES", 2)

CLK_PERIOD_NS = 10.0
DATA_MASK = (1 << DATA_BITS) - 1
FRAME_BITS = 1 + DATA_BITS + (1 if PARITY else 0) + STOP_BITS


def assert_same(actual, expected, message: str) -> None:
    """Equality for lists and tuples; socip's assert_eq compares integers."""
    assert actual == expected, f"{message}: got {actual!r}, expected {expected!r}"


def parity_bit(data: int) -> int:
    ones = bin(data & DATA_MASK).count("1") & 1
    return ones if PARITY == 1 else ones ^ 1


def frame_bits(data: int, *, bad_parity: bool = False,
               stop_level: int = 1) -> list[int]:
    """The line levels of one frame, first bit first."""
    bits = [0] + [(data >> i) & 1 for i in range(DATA_BITS)]
    if PARITY:
        bits.append(parity_bit(data) ^ int(bad_parity))
    bits += [stop_level] + [1] * (STOP_BITS - 1)
    return bits


class TxMonitor:
    """Decodes txd, checking every bit lasts exactly clks_per_bit cycles."""

    def __init__(self, dut, cpb: int) -> None:
        self.dut = dut
        self.cpb = cpb
        self.frames: deque[int] = deque()
        self.errors: list[str] = []
        self._task = cocotb.start_soon(self._run())

    def stop(self) -> None:
        self._task.kill()

    async def _sample(self) -> int:
        await RisingEdge(self.dut.clk)
        await ReadOnly()
        return int(self.dut.txd.value)

    async def _run(self) -> None:
        while True:
            if await self._sample() != 0:
                continue
            levels = [0]
            for _ in range(FRAME_BITS * self.cpb - 1):
                levels.append(await self._sample())
            bits = []
            for b in range(FRAME_BITS):
                chunk = levels[b * self.cpb:(b + 1) * self.cpb]
                if len(set(chunk)) != 1:
                    self.errors.append(f"bit {b} not stable for "
                                       f"{self.cpb} cycles: {chunk}")
                bits.append(chunk[0])
            data = sum(bit << i for i, bit in enumerate(bits[1:1 + DATA_BITS]))
            expected = frame_bits(data)
            if bits != expected:
                self.errors.append(f"frame {bits} != expected {expected}")
            self.frames.append(data)

    async def expect(self, words: list[int], timeout_frames: int = 4) -> None:
        budget = (len(words) + timeout_frames) * (FRAME_BITS + 1) * self.cpb
        for _ in range(budget):
            if len(self.frames) >= len(words):
                break
            await RisingEdge(self.dut.clk)
        await NextTimeStep()
        assert not self.errors, "; ".join(self.errors[:3])
        got = [self.frames.popleft() for _ in range(min(len(words),
                                                        len(self.frames)))]
        assert_same(got, [w & DATA_MASK for w in words], "transmitted words")


class RxCollector:
    """Drives m_ready and records accepted characters and overruns."""

    def __init__(self, dut, rng: RandomStream | None = None,
                 ready_probability: float = 1.0) -> None:
        self.dut = dut
        self.rng = rng
        self.ready_probability = ready_probability
        self.chars: list[tuple[int, int, int]] = []
        self.overruns = 0
        self.ready = True
        dut.m_ready.value = 1
        self._task = cocotb.start_soon(self._run())

    def stop(self) -> None:
        self._task.kill()

    async def _run(self) -> None:
        while True:
            await RisingEdge(self.dut.clk)
            if self.rng is not None:
                self.ready = self.rng.boolean(self.ready_probability)
            self.dut.m_ready.value = int(self.ready)
            await ReadOnly()
            if int(self.dut.rx_overrun.value):
                self.overruns += 1
            if int(self.dut.m_valid.value) and int(self.dut.m_ready.value):
                self.chars.append((int(self.dut.m_data.value),
                                   int(self.dut.m_parity_err.value),
                                   int(self.dut.m_frame_err.value)))


async def drive_rx(dut, levels: list[int], bit_ns: float) -> None:
    """Put line levels on rxd, each for bit_ns, unaligned to the clock."""
    for level in levels:
        dut.rxd.value = level
        await Timer(round(bit_ns * 1000), units="ps")
    dut.rxd.value = 1


async def send_rx(dut, data: int, cpb: int, *, scale: float = 1.0,
                  bad_parity: bool = False, stop_level: int = 1) -> None:
    await drive_rx(dut, frame_bits(data, bad_parity=bad_parity,
                                   stop_level=stop_level),
                   cpb * CLK_PERIOD_NS * scale)


async def setup(dut, cpb: int) -> ClockDomain:
    """Start the clock - once per test - and reset at the given bit period."""
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    await restart(dut, domain, cpb)
    return domain


async def restart(dut, domain: ClockDomain, cpb: int) -> None:
    """Reset into an idle state at a new bit period, clock left running."""
    dut._log.info("uart: DATA_BITS=%d PARITY=%d STOP_BITS=%d clks_per_bit=%d, %s",
                  DATA_BITS, PARITY, STOP_BITS, cpb, describe())
    dut.clks_per_bit.value = cpb
    dut.s_valid.value = 0
    dut.s_data.value = 0
    dut.m_ready.value = 1
    dut.rxd.value = 1
    await domain.reset()


async def send_tx(dut, data: int) -> None:
    """Hand one word to the transmitter, waiting for s_ready."""
    dut.s_data.value = data & DATA_MASK
    dut.s_valid.value = 1
    while True:
        await ReadOnly()
        if int(dut.s_ready.value):
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.s_valid.value = 0


async def wait_chars(dut, rx: RxCollector, count: int, cpb: int) -> None:
    for _ in range((count + 2) * (FRAME_BITS + 2) * cpb):
        if len(rx.chars) >= count:
            break
        await RisingEdge(dut.clk)
    await NextTimeStep()


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: line idle high, transmitter ready, nothing received."""
    await setup(dut, 16)
    await ReadOnly()
    assert_eq(int(dut.txd.value), 1, "txd idles high")
    assert_eq(int(dut.s_ready.value), 1, "transmitter ready")
    assert_eq(int(dut.m_valid.value), 0, "nothing received")
    assert_eq(int(dut.rx_overrun.value), 0, "no overrun")


@cocotb.test()
async def test_transmit_frames(dut) -> None:
    """Directed: corner words go out with the exact frame and bit timing."""
    cpb = 16
    await setup(dut, cpb)
    monitor = TxMonitor(dut, cpb)
    words = [0, DATA_MASK, 0x55 & DATA_MASK, 0xAA & DATA_MASK, 1,
             1 << (DATA_BITS - 1)]
    for w in words:
        await send_tx(dut, w)
        await monitor.expect([w])
    monitor.stop()


@cocotb.test()
async def test_transmit_back_to_back(dut) -> None:
    """Regression: a continuous stream keeps every bit period exact."""
    cpb = 8
    await setup(dut, cpb)
    monitor = TxMonitor(dut, cpb)
    words = [(i * 37 + 11) & DATA_MASK for i in range(24)]

    async def feed() -> None:
        for w in words:
            await send_tx(dut, w)

    cocotb.start_soon(feed())
    await monitor.expect(words)
    monitor.stop()


@cocotb.test()
async def test_receive_characters(dut) -> None:
    """Directed: corner characters are received without error flags."""
    cpb = 16
    await setup(dut, cpb)
    rx = RxCollector(dut)
    words = [0, DATA_MASK, 0x55 & DATA_MASK, 0xAA & DATA_MASK, 1,
             1 << (DATA_BITS - 1)]
    for w in words:
        await send_rx(dut, w, cpb)
    await wait_chars(dut, rx, len(words), cpb)
    assert_same(rx.chars, [(w, 0, 0) for w in words], "received characters")


@cocotb.test()
async def test_parity_error(dut) -> None:
    """Directed: a wrong parity bit is reported with the character."""
    if not PARITY:
        dut._log.info("PARITY=0: no parity bit to corrupt")
        return
    cpb = 16
    await setup(dut, cpb)
    rx = RxCollector(dut)
    await send_rx(dut, 0x5A & DATA_MASK, cpb, bad_parity=True)
    await send_rx(dut, 0x5A & DATA_MASK, cpb)
    await wait_chars(dut, rx, 2, cpb)
    assert_same(rx.chars, [(0x5A & DATA_MASK, 1, 0), (0x5A & DATA_MASK, 0, 0)],
              "parity error only on the corrupted character")


@cocotb.test()
async def test_framing_error_and_break(dut) -> None:
    """Regression: a break gives exactly one character, then recovery."""
    cpb = 16
    await setup(dut, cpb)
    rx = RxCollector(dut)
    # A break: the line low for three frame times.
    await drive_rx(dut, [0], 3 * FRAME_BITS * cpb * CLK_PERIOD_NS)
    await drive_rx(dut, [1], 2 * cpb * CLK_PERIOD_NS)
    await send_rx(dut, 0x3C & DATA_MASK, cpb)
    await wait_chars(dut, rx, 2, cpb)
    assert_eq(len(rx.chars), 2, "one break character plus one real one")
    data, _perr, ferr = rx.chars[0]
    assert_same((data, ferr), (0, 1), "break reads as zero with framing error")
    assert_same(rx.chars[1], (0x3C & DATA_MASK, 0, 0), "recovered after break")


@cocotb.test()
async def test_stop_bit_low(dut) -> None:
    """Directed: a low stop bit is a framing error on that character."""
    cpb = 16
    await setup(dut, cpb)
    rx = RxCollector(dut)
    await send_rx(dut, 0x21 & DATA_MASK, cpb, stop_level=0)
    await drive_rx(dut, [1], cpb * CLK_PERIOD_NS)
    await send_rx(dut, 0x42 & DATA_MASK, cpb)
    await wait_chars(dut, rx, 2, cpb)
    assert_eq(rx.chars[0][0], 0x21 & DATA_MASK, "data still delivered")
    assert_eq(rx.chars[0][2], 1, "framing error flagged")
    assert_same(rx.chars[1], (0x42 & DATA_MASK, 0, 0), "next character clean")


@cocotb.test()
async def test_start_glitch_rejected(dut) -> None:
    """Directed: a low pulse shorter than half a bit is not a character."""
    cpb = 16
    await setup(dut, cpb)
    rx = RxCollector(dut)
    for width in (1, 3, cpb // 2 - 3):
        await drive_rx(dut, [0], width * CLK_PERIOD_NS)
        await drive_rx(dut, [1], 2 * FRAME_BITS * cpb * CLK_PERIOD_NS)
    assert_same(rx.chars, [], "no character from glitches")
    await send_rx(dut, 0x66 & DATA_MASK, cpb)
    await wait_chars(dut, rx, 1, cpb)
    assert_same(rx.chars, [(0x66 & DATA_MASK, 0, 0)], "real character after")


@cocotb.test()
async def test_overrun(dut) -> None:
    """Directed: an unread character is kept; the next one is dropped."""
    cpb = 16
    await setup(dut, cpb)
    rx = RxCollector(dut)
    rx.ready = False
    rx.rng = None
    dut.m_ready.value = 0
    await send_rx(dut, 0x11 & DATA_MASK, cpb)
    await send_rx(dut, 0x22 & DATA_MASK, cpb)
    await drive_rx(dut, [1], 2 * cpb * CLK_PERIOD_NS)
    assert_eq(rx.overruns, 1, "one overrun pulse")
    rx.ready = True
    await wait_chars(dut, rx, 1, cpb)
    for _ in range(4):
        await RisingEdge(dut.clk)
    assert_same(rx.chars, [(0x11 & DATA_MASK, 0, 0)], "the first character kept")


@cocotb.test()
async def test_bit_period_extremes(dut) -> None:
    """Directed: the minimum period of 4 and an odd period both work."""
    domain = await setup(dut, 4)
    for cpb in (4, 37):
        await restart(dut, domain, cpb)
        rx = RxCollector(dut)
        monitor = TxMonitor(dut, cpb)
        words = [0xA5 & DATA_MASK, 0x0F & DATA_MASK]
        for w in words:
            await send_tx(dut, w)
            await send_rx(dut, w, cpb)
        await monitor.expect(words)
        await wait_chars(dut, rx, len(words), cpb)
        assert_same(rx.chars, [(w, 0, 0) for w in words], f"cpb={cpb}")
        monitor.stop()
        rx.stop()


@cocotb.test()
async def test_baud_tolerance(dut) -> None:
    """Regression: a transmitter 3 % fast or slow is received correctly."""
    cpb = 16
    await setup(dut, cpb)
    rx = RxCollector(dut)
    words = [0x00, DATA_MASK, 0x55 & DATA_MASK, 0xAA & DATA_MASK]
    for scale in (0.97, 1.03):
        rx.chars.clear()
        for w in words:
            await send_rx(dut, w, cpb, scale=scale)
        await wait_chars(dut, rx, len(words), cpb)
        assert_same(rx.chars, [(w, 0, 0) for w in words], f"scale {scale}")


# ---------------------------------------------------------------------------
# Randomised
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_loopback(dut) -> None:
    """Randomised: txd looped to rxd, random words, periods, back-pressure."""
    rng = RandomStream("uart_loopback")
    dut._log.info("random seed = %d", rng.seed)

    domain = await setup(dut, 16)
    for _ in range(4):
        cpb = rng.between(4, 40)
        await restart(dut, domain, cpb)
        rx = RxCollector(dut, rng, ready_probability=0.7)

        async def loop() -> None:
            while True:
                await RisingEdge(dut.clk)
                await ReadOnly()
                level = int(dut.txd.value)
                await NextTimeStep()
                dut.rxd.value = level

        looper = cocotb.start_soon(loop())
        words = [rng.uint(DATA_BITS) for _ in range(30)]
        for w in words:
            await send_tx(dut, w)
        await wait_chars(dut, rx, len(words), cpb)
        looper.kill()
        rx.stop()
        # The transmitter paces itself, so a reader that is ready 70 % of the
        # time always empties the holding register within a frame.
        assert_eq(rx.overruns, 0, f"no overrun at cpb={cpb}")
        assert_same([c[0] for c in rx.chars], words, f"loopback at cpb={cpb}")
        assert_eq(sum(c[1] + c[2] for c in rx.chars), 0, "no error flags")
