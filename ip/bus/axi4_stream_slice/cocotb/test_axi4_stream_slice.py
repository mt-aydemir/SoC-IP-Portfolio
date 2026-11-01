"""Cocotb regression for axi4_stream_slice.

Coverage
    directed   the reset state, the latency of the first beat, the throughput
               of a continuous stream, every sideband carried through, a
               stalled output that fills the slice and then drains it, and a
               reset mid-stream
    randomised source gaps and sink back-pressure drawn at random over
               thousands of beats, every beat compared in order
    regression the paths the selected MODE claims to cut really are cut: a
               TREADY or a TVALID that changes in the middle of a cycle must
               not reach the other side before the edge

The expectations - latency, throughput, which paths are combinational - are
derived from the MODE table in the RTL header. One coroutine runs every cycle:
drive the source and sink after the edge, let them settle, sample the slice,
change the late-arriving inputs, sample again, and resolve the handshakes the
next edge will see.
"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass

import cocotb
from cocotb.triggers import RisingEdge, Timer

from socip import ClockDomain, RandomStream, assert_eq, describe, get_param

MODE = get_param("MODE", 3)
DATA_WIDTH = get_param("DATA_WIDTH", 32)
ID_WIDTH = get_param("ID_WIDTH", 1)
DEST_WIDTH = get_param("DEST_WIDTH", 1)
USER_WIDTH = get_param("USER_WIDTH", 1)

CLK_PERIOD_NS = 10.0
STRB_WIDTH = DATA_WIDTH // 8
BYPASS, FORWARD, REVERSE, FULL, LIGHT = range(5)
MODE_NAMES = ["BYPASS", "FORWARD", "REVERSE", "FULL", "LIGHT"]

LATENCY = 1 if MODE in (FORWARD, FULL, LIGHT) else 0
# Which inputs may reach which outputs within a cycle.
READY_IS_COMBINATIONAL = MODE in (BYPASS, FORWARD)      # m_tready -> s_tready
VALID_IS_COMBINATIONAL = MODE in (BYPASS, REVERSE)      # s_tvalid -> m_tvalid

FIELDS = [("tdata", DATA_WIDTH), ("tstrb", STRB_WIDTH), ("tkeep", STRB_WIDTH),
          ("tlast", 1), ("tid", ID_WIDTH), ("tdest", DEST_WIDTH),
          ("tuser", USER_WIDTH)]


@dataclass(frozen=True)
class Beat:
    tdata: int
    tstrb: int
    tkeep: int
    tlast: int
    tid: int
    tdest: int
    tuser: int

    @staticmethod
    def random(rng: RandomStream) -> "Beat":
        return Beat(*(rng.corner_uint(w) for _, w in FIELDS))


class Harness:
    def __init__(self, dut, domain: ClockDomain, rng: RandomStream) -> None:
        self.dut = dut
        self.domain = domain
        self.rng = rng
        self.source: deque[Beat] = deque()
        self.expected: deque[Beat] = deque()
        self.received: list[Beat] = []
        self.valid_probability = 1.0
        self.ready_probability = 1.0
        self.late_changes = False
        self.cycle = 0
        self.first_out: int | None = None
        self.current: Beat | None = None

    def drive_beat(self, beat: Beat | None) -> None:
        for name, _ in FIELDS:
            getattr(self.dut, f"s_axis_{name}").value = getattr(beat, name) if beat else 0

    def idle(self) -> None:
        self.dut.s_axis_tvalid.value = 0
        self.dut.m_axis_tready.value = 0
        self.drive_beat(None)
        self.current = None

    async def reset(self) -> None:
        self.idle()
        await self.domain.reset()
        self.source.clear()
        self.expected.clear()

    def output_beat(self) -> Beat:
        return Beat(*(int(getattr(self.dut, f"m_axis_{n}").value) for n, _ in FIELDS))

    async def step(self) -> None:
        d = self.dut
        # A beat on offer stays on offer until taken; a new one is offered
        # with valid_probability.
        if self.current is None and self.source and self.rng.boolean(self.valid_probability):
            self.current = self.source[0]
        d.s_axis_tvalid.value = int(self.current is not None)
        self.drive_beat(self.current)
        ready = self.rng.boolean(self.ready_probability)
        d.m_axis_tready.value = int(ready)

        await Timer(CLK_PERIOD_NS / 4, units="ns")
        early = (int(d.s_axis_tready.value), int(d.m_axis_tvalid.value), self.output_beat())

        if self.late_changes:
            # Inputs that arrive late in the cycle: TREADY may change freely,
            # and TVALID may rise (never fall) with a new beat.
            ready = self.rng.boolean(self.ready_probability)
            d.m_axis_tready.value = int(ready)
            if self.current is None and self.source and self.rng.boolean():
                self.current = self.source[0]
                d.s_axis_tvalid.value = 1
                self.drive_beat(self.current)

        await Timer(CLK_PERIOD_NS / 4, units="ns")
        s_ready = int(d.s_axis_tready.value)
        m_valid = int(d.m_axis_tvalid.value)
        out = self.output_beat()
        if self.late_changes:
            if not READY_IS_COMBINATIONAL:
                assert_eq(s_ready, early[0], f"cycle {self.cycle}: s_axis_tready "
                          f"followed a late m_axis_tready in {MODE_NAMES[MODE]}")
            if not VALID_IS_COMBINATIONAL:
                assert_eq(m_valid, early[1], f"cycle {self.cycle}: m_axis_tvalid "
                          f"followed a late s_axis_tvalid in {MODE_NAMES[MODE]}")
                if m_valid and out != early[2]:
                    raise AssertionError(f"cycle {self.cycle}: output payload "
                                         f"followed the input in {MODE_NAMES[MODE]}")

        await RisingEdge(d.clk)
        self.cycle += 1

        if self.current is not None and s_ready:
            self.expected.append(self.source.popleft())
            self.current = None
        if m_valid and ready:
            if not self.expected:
                raise AssertionError(f"cycle {self.cycle}: beat out with none in")
            want = self.expected.popleft()
            if out != want:
                raise AssertionError(f"cycle {self.cycle}: beat {len(self.received)} "
                                     f"is {out}, expected {want}")
            self.received.append(out)
            if self.first_out is None:
                self.first_out = self.cycle

    async def run(self, beats: list[Beat], limit: int = 100000) -> int:
        """Send beats and wait for all of them; return the cycles taken."""
        start = self.cycle
        count = len(self.received)
        self.source.extend(beats)
        while self.source or self.expected or self.current is not None:
            await self.step()
            if self.cycle - start > limit:
                raise AssertionError("stream did not drain")
        assert_eq(len(self.received) - count, len(beats), "beats delivered")
        return self.cycle - start


async def setup(dut, name: str) -> Harness:
    dut._log.info("axi4_stream_slice: MODE=%d (%s) DATA_WIDTH=%d, %s",
                  MODE, MODE_NAMES[MODE], DATA_WIDTH, describe())
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    h = Harness(dut, domain, RandomStream(name))
    await h.reset()
    return h


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: the slice comes out of reset empty."""
    h = await setup(dut, "axis_reset")
    await h.step()
    assert_eq(int(dut.m_axis_tvalid.value), 0, "m_axis_tvalid")


@cocotb.test()
async def test_latency(dut) -> None:
    """Directed: the first beat appears after the mode's latency."""
    h = await setup(dut, "axis_latency")
    start = h.cycle
    await h.run([Beat.random(h.rng)])
    assert_eq(h.first_out - start - 1, LATENCY, f"latency in {MODE_NAMES[MODE]}")


@cocotb.test()
async def test_throughput(dut) -> None:
    """Directed: a continuous stream runs at the mode's full rate."""
    h = await setup(dut, "axis_rate")
    n = 200
    cycles = await h.run([Beat.random(h.rng) for _ in range(n)])
    expected = 2 * n if MODE == LIGHT else n + LATENCY
    assert_eq(cycles, expected, f"cycles for {n} beats in {MODE_NAMES[MODE]}")


@cocotb.test()
async def test_sidebands(dut) -> None:
    """Directed: every sideband at its extremes is carried through."""
    h = await setup(dut, "axis_sideband")
    beats = [Beat(*((1 << w) - 1 if (i >> k) & 1 else 0 for k, (_, w) in enumerate(FIELDS)))
             for i in range(1 << len(FIELDS))]
    await h.run(beats)


@cocotb.test()
async def test_stall_and_drain(dut) -> None:
    """Directed: a stalled sink fills the slice, which then drains in order."""
    h = await setup(dut, "axis_stall")
    h.ready_probability = 0.0
    h.source.extend(Beat.random(h.rng) for _ in range(8))
    for _ in range(10):
        await h.step()
    held = len(h.expected)
    capacity = {BYPASS: 0, FORWARD: 1, REVERSE: 1, FULL: 2, LIGHT: 1}[MODE]
    assert_eq(held, capacity, f"beats accepted while stalled in {MODE_NAMES[MODE]}")
    h.ready_probability = 1.0
    while h.source or h.expected or h.current is not None:
        await h.step()
    assert_eq(len(h.received), 8, "beats delivered after the stall")


@cocotb.test()
async def test_reset_mid_stream(dut) -> None:
    """Directed: a reset empties the slice; the stream restarts cleanly."""
    h = await setup(dut, "axis_midreset")
    h.ready_probability = 0.0
    h.source.extend(Beat.random(h.rng) for _ in range(4))
    for _ in range(4):
        await h.step()
    await h.reset()
    h.current = None
    await h.step()
    assert_eq(int(dut.m_axis_tvalid.value), 0, "m_axis_tvalid after reset")
    h.ready_probability = 1.0
    await h.run([Beat.random(h.rng) for _ in range(20)])


# ---------------------------------------------------------------------------
# Randomised and structural
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_flow(dut) -> None:
    """Randomised: source gaps and sink back-pressure."""
    h = await setup(dut, "axis_random")
    for valid_p, ready_p in [(0.9, 0.9), (0.3, 0.9), (0.9, 0.3), (0.5, 0.5)]:
        h.valid_probability = valid_p
        h.ready_probability = ready_p
        await h.run([Beat.random(h.rng) for _ in range(1500)])


@cocotb.test()
async def test_cut_paths(dut) -> None:
    """Structural: the paths the mode cuts do not change within a cycle."""
    h = await setup(dut, "axis_paths")
    h.late_changes = True
    h.valid_probability = 0.5
    h.ready_probability = 0.5
    await h.run([Beat.random(h.rng) for _ in range(2000)])
