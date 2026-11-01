"""Cocotb regression for the cdc_stream_bridge integration example.

Coverage
    directed   both domains idle after reset; a single word crosses; a burst
               longer than the FIFO crosses intact
    randomised random traffic with back-pressure and idle gaps on both sides,
               with the source clock faster and then slower than the
               destination
    regression a reset in the middle of traffic leaves no phantom words, and
               the bridge is usable immediately afterwards

The two clocks run at periods with no common factor short of their product,
so the phase relationship between their edges drifts through every value
during a run. That is the condition under which a crossing bug - as opposed to
a FIFO bug - becomes visible.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Timer

from socip import (RandomStream, StreamSink, StreamSource, describe, get_param,
                   sampled)

DATA_WIDTH = get_param("DATA_WIDTH", 32)
DEPTH = get_param("DEPTH", 16)
SYNC_STAGES = get_param("SYNC_STAGES", 2)

MASK = (1 << DATA_WIDTH) - 1


async def setup(dut, src_period_ns: float, dst_period_ns: float,
                ready_probability: float = 1.0,
                rng: RandomStream | None = None
                ) -> tuple[StreamSource, StreamSink]:
    """Start both clocks, pulse the raw reset, and return the transactors."""
    dut._log.info("cdc_stream_bridge: DATA_WIDTH=%d DEPTH=%d SYNC_STAGES=%d, "
                  "src %.1f ns, dst %.1f ns, %s", DATA_WIDTH, DEPTH,
                  SYNC_STAGES, src_period_ns, dst_period_ns, describe())

    cocotb.start_soon(Clock(dut.src_clk, src_period_ns, units="ns").start())
    cocotb.start_soon(Clock(dut.dst_clk, dst_period_ns, units="ns").start())

    source = StreamSource(dut.src_clk, dut.s_valid, dut.s_ready, dut.s_data, "src")
    sink = StreamSink(dut.dst_clk, dut.m_valid, dut.m_ready, dut.m_data,
                      name="dst", ready_probability=ready_probability, rng=rng)
    source.idle()
    dut.m_ready.value = 1

    await pulse_reset(dut)
    sink.start()
    return source, sink


async def pulse_reset(dut) -> None:
    """Assert the raw reset with no alignment to either clock, then release.

    Held long enough for both synchronisers to see it, and released at an
    arbitrary instant - which is the point of having synchronisers.
    """
    dut.arst_n.value = 0
    await Timer(97, units="ns")
    dut.arst_n.value = 1
    # Wait for the release to propagate through both synchronisers.
    await ClockCycles(dut.src_clk, SYNC_STAGES + 2)
    await ClockCycles(dut.dst_clk, SYNC_STAGES + 2)


async def expect_in_order(sink: StreamSink, values: list[int],
                          timeout_cycles: int = 50_000) -> None:
    for _ in range(timeout_cycles):
        if sink.count >= len(values):
            break
        await ClockCycles(sink.clk, 1)
    else:
        raise AssertionError(
            f"only {sink.count} of {len(values)} words crossed")
    for index, (want, got) in enumerate(zip(values, sink.received)):
        if want != got:
            raise AssertionError(
                f"word {index}: expected 0x{want:X}, got 0x{got:X}")
    if sink.count != len(values):
        raise AssertionError(
            f"{sink.count - len(values)} extra word(s) appeared at the output")


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: nothing is presented and the input is open after reset."""
    await setup(dut, 7.0, 10.0)
    assert await sampled(dut.m_valid) == 0, "m_valid after reset"
    await ClockCycles(dut.src_clk, 2)
    assert await sampled(dut.s_ready) == 1, "s_ready after reset"
    await ClockCycles(dut.src_clk, 1)


@cocotb.test()
async def test_single_word(dut) -> None:
    """Directed: one word crosses."""
    source, sink = await setup(dut, 7.0, 10.0)
    await source.send(0xC0FFEE & MASK)
    await expect_in_order(sink, [0xC0FFEE & MASK])


@cocotb.test()
async def test_burst_longer_than_fifo(dut) -> None:
    """Directed: a burst of several FIFO depths, into a slower destination.

    The source must be throttled by s_ready rather than losing words once the
    FIFO fills, which is the back-pressure path crossing the domains.
    """
    source, sink = await setup(dut, 5.0, 13.0)
    values = [(0x1000 + i) & MASK for i in range(4 * DEPTH)]
    await source.send_many(values)
    await expect_in_order(sink, values)


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_fast_to_slow(dut) -> None:
    """Randomised: fast source, slow destination, back-pressure on both sides."""
    rng = RandomStream("bridge_fast_slow")
    dut._log.info("random seed = %d", rng.seed)
    source, sink = await setup(dut, 6.0, 11.0, ready_probability=0.7, rng=rng)

    values = [rng.corner_uint(DATA_WIDTH) for _ in range(300)]
    await source.send_many(values, gap=rng.delay)
    await expect_in_order(sink, values)


@cocotb.test()
async def test_random_slow_to_fast(dut) -> None:
    """Randomised: slow source, fast destination, back-pressure on both sides.

    The FIFO runs near empty in this direction, so every word exercises the
    empty-flag crossing rather than the full-flag one.
    """
    rng = RandomStream("bridge_slow_fast")
    dut._log.info("random seed = %d", rng.seed)
    source, sink = await setup(dut, 11.0, 6.0, ready_probability=0.7, rng=rng)

    values = [rng.corner_uint(DATA_WIDTH) for _ in range(300)]
    await source.send_many(values, gap=rng.delay)
    await expect_in_order(sink, values)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_during_traffic(dut) -> None:
    """Regression: a reset mid-stream leaves no phantom words behind.

    This is what resetting both sides of the FIFO from one source buys. If the
    two domains came out of reset with pointers that disagreed, the read side
    would present words that were never written in this session.
    """
    rng = RandomStream("bridge_reset")
    source, sink = await setup(dut, 7.0, 10.0)

    await source.send_many([rng.uint(DATA_WIDTH) for _ in range(DEPTH // 2)])
    source.idle()
    await pulse_reset(dut)

    # Discard whatever crossed before the reset; only post-reset traffic counts.
    sink.received.clear()
    sink._queue.clear()

    await ClockCycles(dut.dst_clk, 20)
    assert sink.count == 0, f"{sink.count} phantom word(s) after reset"

    values = [(0xA000 + i) & MASK for i in range(DEPTH)]
    await source.send_many(values)
    await expect_in_order(sink, values)
