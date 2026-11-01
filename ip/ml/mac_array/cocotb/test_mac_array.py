"""Cocotb regression for mac_array.

Coverage
    directed   the reset state, the product corners for the configured
               signedness (most negative times most negative, largest
               unsigned times largest unsigned, and the mixed extremes) in
               every lane at once, single-beat and multi-beat vectors, one
               beat per cycle and the exact latency, a result left waiting
               under back-pressure, full rate when every beat ends a vector,
               exactly DEPTH results accepted against a stalled sink, the
               accumulator wrapping modulo
               2**ACC_WIDTH, and a reset in the middle of a vector
    randomised random vectors of 1 to 12 beats with corner-biased operands,
               source gaps and sink back-pressure, against the model and
               against numpy dot products on the same data

The reference model is written from the RTL header: a dot product is the
sum over its beats and lanes of a[i] * b[i], each operand read as two's
complement or unsigned per A_SIGNED and B_SIGNED, reduced modulo
2**ACC_WIDTH. One coroutine runs every cycle: drive after the edge, settle,
sample, and resolve the handshakes the next edge will see.
"""
from __future__ import annotations

from collections import deque

import cocotb
import numpy as np
from cocotb.triggers import RisingEdge, Timer

from socip import ClockDomain, RandomStream, assert_eq, describe, get_param, to_signed

LANES = get_param("LANES", 16)
DATA_WIDTH = get_param("DATA_WIDTH", 8)
ACC_WIDTH = get_param("ACC_WIDTH", 32)
A_SIGNED = get_param("A_SIGNED", 1)
B_SIGNED = get_param("B_SIGNED", 1)

CLK_PERIOD_NS = 10.0
LEVELS = (LANES - 1).bit_length() if LANES > 1 else 0
LATENCY = LEVELS + 2
DEPTH = LEVELS + 3                  # output FIFO entries, and credits
ACC_MASK = (1 << ACC_WIDTH) - 1
D_MASK = (1 << DATA_WIDTH) - 1


def value_range(signed: int) -> tuple[int, int]:
    if signed:
        return -(1 << (DATA_WIDTH - 1)), (1 << (DATA_WIDTH - 1)) - 1
    return 0, D_MASK


A_MIN, A_MAX = value_range(A_SIGNED)
B_MIN, B_MAX = value_range(B_SIGNED)

Beat = tuple[list[int], list[int], bool]        # a lanes, b lanes, last


def pack(values: list[int]) -> int:
    word = 0
    for i, v in enumerate(values):
        word |= (v & D_MASK) << (i * DATA_WIDTH)
    return word


def beat_sum(a: list[int], b: list[int]) -> int:
    return sum(x * y for x, y in zip(a, b))


class Harness:
    def __init__(self, dut, domain: ClockDomain, rng: RandomStream) -> None:
        self.dut = dut
        self.domain = domain
        self.rng = rng
        self.source: deque[Beat] = deque()
        self.expected: deque[int] = deque()
        self.outputs: list[int] = []
        self.partial = 0
        self.valid_probability = 1.0
        self.ready_probability = 1.0
        self.current: Beat | None = None
        self.cycle = 0
        self.last_cycles: list[int] = []
        self.output_cycles: list[int] = []

    def idle(self) -> None:
        d = self.dut
        d.s_valid.value = 0
        d.s_a.value = 0
        d.s_b.value = 0
        d.s_last.value = 0
        d.m_ready.value = 0
        self.current = None

    async def reset(self) -> None:
        self.idle()
        await self.domain.reset()
        self.source.clear()
        self.expected.clear()
        self.partial = 0

    def vector(self, beats: list[tuple[list[int], list[int]]]) -> int:
        """Queue one dot product; return its exact (unreduced) value."""
        for n, (a, b) in enumerate(beats):
            self.source.append((a, b, n == len(beats) - 1))
        return sum(beat_sum(a, b) for a, b in beats)

    async def step(self) -> None:
        d = self.dut
        if self.current is None and self.source and self.rng.boolean(self.valid_probability):
            self.current = self.source[0]
        beat = self.current
        d.s_valid.value = int(beat is not None)
        d.s_a.value = pack(beat[0]) if beat else self.rng.uint(LANES * DATA_WIDTH)
        d.s_b.value = pack(beat[1]) if beat else self.rng.uint(LANES * DATA_WIDTH)
        d.s_last.value = int(beat[2]) if beat else self.rng.uint(1)
        ready = self.rng.boolean(self.ready_probability)
        d.m_ready.value = int(ready)

        await Timer(CLK_PERIOD_NS / 2, units="ns")
        s_ready = int(d.s_ready.value)
        m_valid = int(d.m_valid.value)
        out = int(d.m_data.value)

        await RisingEdge(d.clk)
        self.cycle += 1
        if m_valid and ready:
            if not self.expected:
                raise AssertionError(f"cycle {self.cycle}: result with no vector")
            want = self.expected.popleft()
            if out != want:
                raise AssertionError(f"cycle {self.cycle}: result {len(self.outputs)} is "
                                     f"{to_signed(out, ACC_WIDTH)}, expected "
                                     f"{to_signed(want, ACC_WIDTH)}")
            self.outputs.append(out)
            self.output_cycles.append(self.cycle)
        if beat is not None and s_ready:
            self.partial += beat_sum(beat[0], beat[1])
            if beat[2]:
                self.expected.append(self.partial & ACC_MASK)
                self.partial = 0
                self.last_cycles.append(self.cycle)
            self.source.popleft()
            self.current = None

    async def drain(self, limit: int = 500000) -> list[int]:
        start = len(self.outputs)
        begin = self.cycle
        while self.source or self.expected or self.current is not None:
            await self.step()
            if self.cycle - begin > limit:
                raise AssertionError("vectors did not drain")
        return self.outputs[start:]


async def setup(dut, name: str) -> Harness:
    dut._log.info("mac_array: LANES=%d DATA_WIDTH=%d ACC_WIDTH=%d A_SIGNED=%d B_SIGNED=%d, %s",
                  LANES, DATA_WIDTH, ACC_WIDTH, A_SIGNED, B_SIGNED, describe())
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    h = Harness(dut, domain, RandomStream(name))
    await h.reset()
    return h


def rand_operand(rng: RandomStream, signed: int) -> int:
    raw = rng.corner_uint(DATA_WIDTH)
    return to_signed(raw, DATA_WIDTH) if signed else raw


def rand_beat(rng: RandomStream) -> tuple[list[int], list[int]]:
    return ([rand_operand(rng, A_SIGNED) for _ in range(LANES)],
            [rand_operand(rng, B_SIGNED) for _ in range(LANES)])


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: empty output and ready input after reset."""
    await setup(dut, "mac_reset")
    assert_eq(int(dut.m_valid.value), 0, "m_valid after reset")
    assert_eq(int(dut.s_ready.value), 1, "s_ready after reset")


@cocotb.test()
async def test_product_corners(dut) -> None:
    """Directed: the extreme products in every lane at once, one beat each."""
    h = await setup(dut, "mac_corners")
    corners = [(a, b) for a in (A_MIN, A_MAX, 0, 1) for b in (B_MIN, B_MAX, 0, 1)]
    for a, b in corners:
        exact = h.vector([([a] * LANES, [b] * LANES)])
        out = await h.drain()
        assert_eq(to_signed(out[0], ACC_WIDTH), exact, f"{a} * {b} in every lane")
    # Each lane on its own, to catch a lane wired to the wrong bits.
    for lane in range(LANES):
        a = [0] * LANES
        b = [0] * LANES
        a[lane], b[lane] = A_MIN if A_SIGNED else A_MAX, B_MAX
        exact = h.vector([(a, b)])
        out = await h.drain()
        assert_eq(to_signed(out[0], ACC_WIDTH), exact, f"lane {lane} alone")


@cocotb.test()
async def test_multi_beat(dut) -> None:
    """Directed: vectors of 1 to 10 beats accumulate across their beats."""
    h = await setup(dut, "mac_beats")
    for n in range(1, 11):
        h.vector([rand_beat(h.rng) for _ in range(n)])
    await h.drain()


@cocotb.test()
async def test_rate_and_latency(dut) -> None:
    """Directed: one beat per cycle, and the result LATENCY cycles after the last beat."""
    h = await setup(dut, "mac_rate")
    n_vectors, beats = 20, 3
    for _ in range(n_vectors):
        h.vector([rand_beat(h.rng) for _ in range(beats)])
    begin = h.cycle
    await h.drain()
    for i in range(n_vectors):
        assert_eq(h.output_cycles[i] - h.last_cycles[i], LATENCY, f"vector {i} latency")
    assert_eq(h.last_cycles[-1] - begin, n_vectors * beats, "one beat per cycle")


@cocotb.test()
async def test_result_waits(dut) -> None:
    """Directed: a result held under back-pressure stalls the whole pipeline intact."""
    h = await setup(dut, "mac_wait")
    for _ in range(6):
        h.vector([rand_beat(h.rng) for _ in range(h.rng.between(1, 3))])
    h.ready_probability = 0.0
    for _ in range(3 * LATENCY + 20):
        await h.step()
    assert_eq(len(h.outputs), 0, "nothing taken while m_ready is low")
    h.ready_probability = 1.0
    await h.drain()


@cocotb.test()
async def test_every_beat_last(dut) -> None:
    """Directed: single-beat vectors back to back still go at one beat per cycle."""
    h = await setup(dut, "mac_all_last")
    n = 60
    for _ in range(n):
        h.vector([rand_beat(h.rng)])
    begin = h.cycle
    await h.drain()
    assert_eq(h.last_cycles[-1] - begin, n, "one single-beat vector per cycle")


@cocotb.test()
async def test_credits(dut) -> None:
    """Directed: against a stalled sink exactly DEPTH results are accepted, then s_ready drops."""
    h = await setup(dut, "mac_credits")
    for _ in range(DEPTH + 5):
        h.vector([rand_beat(h.rng)])
    h.ready_probability = 0.0
    for _ in range(DEPTH + LATENCY + 10):
        await h.step()
    assert_eq(len(h.last_cycles), DEPTH, "vectors accepted while the sink is stalled")
    assert_eq(int(dut.s_ready.value), 0, "s_ready with every credit out")
    h.ready_probability = 1.0
    await h.drain()


@cocotb.test()
async def test_wrap(dut) -> None:
    """Directed: the accumulator wraps modulo 2**ACC_WIDTH, as documented."""
    h = await setup(dut, "mac_wrap")
    a, b = (A_MIN, B_MIN) if A_SIGNED and B_SIGNED else (A_MAX, B_MAX)
    per_beat = LANES * a * b
    beats = (1 << (ACC_WIDTH - 1)) // per_beat + 2
    if beats > 20000:
        dut._log.info("wrap needs %d beats at ACC_WIDTH=%d; skipped", beats, ACC_WIDTH)
        return
    exact = h.vector([([a] * LANES, [b] * LANES)] * beats)
    out = await h.drain()
    assert_eq(int(exact >= (1 << (ACC_WIDTH - 1))), 1, "the true sum overflows")
    assert_eq(out[0], exact & ACC_MASK, f"{beats} beats wrap")


@cocotb.test()
async def test_reset_mid_vector(dut) -> None:
    """Directed: a reset drops a partial sum; the next vector starts from zero."""
    h = await setup(dut, "mac_midreset")
    h.vector([rand_beat(h.rng) for _ in range(8)])
    for _ in range(5):
        await h.step()
    await h.reset()
    assert_eq(int(dut.m_valid.value), 0, "m_valid after reset")
    exact = h.vector([rand_beat(h.rng)])
    out = await h.drain()
    assert_eq(out[0], exact & ACC_MASK, "first vector after reset")


# ---------------------------------------------------------------------------
# Randomised
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_vectors(dut) -> None:
    """Randomised: gaps and back-pressure, against the model and numpy."""
    h = await setup(dut, "mac_random")
    for valid_p, ready_p in [(1.0, 1.0), (0.6, 0.9), (0.9, 0.3), (0.5, 0.5)]:
        h.valid_probability, h.ready_probability = valid_p, ready_p
        exact = []
        for _ in range(40):
            beats = [rand_beat(h.rng) for _ in range(h.rng.between(1, 12))]
            a = np.array([x for bt in beats for x in bt[0]], dtype=np.int64)
            b = np.array([y for bt in beats for y in bt[1]], dtype=np.int64)
            exact.append(int(np.dot(a, b)))
            h.vector(beats)
        out = await h.drain()
        for i, (got, want) in enumerate(zip(out, exact)):
            assert_eq(got, want & ACC_MASK, f"vector {i}: numpy dot product")
    h.valid_probability = h.ready_probability = 1.0
