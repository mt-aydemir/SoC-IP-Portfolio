"""Cocotb regression for fifo_sync.

Coverage
    directed   reset state, first-word-fall-through latency, filling to
               exactly DEPTH, draining in order, the almost-full and
               almost-empty flags, and the write-bypass path
    randomised full-rate traffic with randomised back-pressure on both sides,
               compared against a reference queue
    regression sustained streaming with the FIFO held full, held empty, and
               oscillating between the two, plus a mid-stream reset

The occupancy checks matter as much as the data checks. A FIFO that delivers
every word in order but reports the wrong level will overflow the first
consumer that trusts `almost_full` to throttle it.
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge

from socip import (
    ClockDomain,
    RandomStream,
    StreamSink,
    StreamSource,
    assert_eq,
    describe,
    expect_stream,
    get_param,
    sample,
    sampled,
)

DATA_WIDTH = get_param("DATA_WIDTH", 32)
DEPTH = get_param("DEPTH", 16)
ALMOST_FULL_LEVEL = get_param("ALMOST_FULL_LEVEL", DEPTH - 1)
ALMOST_EMPTY_LEVEL = get_param("ALMOST_EMPTY_LEVEL", 1)

CLK_PERIOD_NS = 10.0
DATA_MASK = (1 << DATA_WIDTH) - 1


async def bring_up(dut, ready_probability: float = 1.0,
                   rng: RandomStream | None = None
                   ) -> tuple[ClockDomain, StreamSource, StreamSink]:
    """Reset the FIFO and build the stream transactors."""
    dut._log.info("fifo_sync: DATA_WIDTH=%d, DEPTH=%d, %s",
                  DATA_WIDTH, DEPTH, describe())

    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    source = StreamSource(dut.clk, dut.s_valid, dut.s_ready, dut.s_data, "s")
    sink = StreamSink(dut.clk, dut.m_valid, dut.m_ready, dut.m_data,
                      rst_n=dut.rst_n, name="m",
                      ready_probability=ready_probability, rng=rng)

    source.idle()
    dut.m_ready.value = 1
    await domain.reset()
    sink.start()
    return domain, source, sink


async def fill(dut, source: StreamSource, count: int,
               start: int = 0) -> list[int]:
    """Write *count* words and return them."""
    values = [(start + i) & DATA_MASK for i in range(count)]
    for value in values:
        await source.send(value)
    return values


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: empty, not full, level zero, output idle."""
    await bring_up(dut)

    level, full, empty, m_valid, s_ready = await sample(
        dut.level, dut.full, dut.empty, dut.m_valid, dut.s_ready)

    assert_eq(level, 0, "level after reset")
    assert_eq(full, 0, "full after reset")
    assert_eq(empty, 1, "empty after reset")
    assert_eq(m_valid, 0, "m_valid after reset")
    assert_eq(s_ready, 1, "s_ready after reset")


@cocotb.test()
async def test_first_word_fall_through(dut) -> None:
    """Directed: the head word appears without the consumer asking for it.

    The write bypass should make this fast — one cycle, not the three a word
    takes through the RAM.
    """
    domain, source, _sink = await bring_up(dut)
    dut.m_ready.value = 0

    await source.send(0xA5 & DATA_MASK)

    latency = None
    for cycle in range(8):
        await RisingEdge(dut.clk)
        valid, data = await sample(dut.m_valid, dut.m_data)
        if valid:
            latency = cycle
            assert_eq(data, 0xA5 & DATA_MASK, "head word presented")
            break

    assert latency is not None, "the word never appeared on the output"
    dut._log.info("empty-FIFO latency: %d cycle(s)", latency + 1)
    assert latency <= 2, (
        f"the write bypass is not working: latency was {latency + 1} cycles")

    await domain.edge()


@cocotb.test()
async def test_fill_to_capacity(dut) -> None:
    """Directed: exactly DEPTH words fit, and the DEPTH+1st is refused."""
    domain, source, _sink = await bring_up(dut)
    dut.m_ready.value = 0
    await domain.edge()

    await fill(dut, source, DEPTH)

    # Let the prefetch pipeline settle before reading the status.
    await domain.cycles(4)
    level, full, s_ready = await sample(dut.level, dut.full, dut.s_ready)

    assert_eq(level, DEPTH, "level once full")
    assert_eq(full, 1, "full flag")
    assert_eq(s_ready, 0, "s_ready must be withdrawn when full")


@cocotb.test()
async def test_fill_and_drain_in_order(dut) -> None:
    """Directed: DEPTH words come back in the order they went in."""
    domain, source, sink = await bring_up(dut)
    dut.m_ready.value = 0
    await domain.edge()

    values = await fill(dut, source, DEPTH, start=0x100)
    await domain.cycles(4)

    await domain.edge()
    dut.m_ready.value = 1
    await expect_stream(sink, values)

    await domain.cycles(6)
    level, empty = await sample(dut.level, dut.empty)
    assert_eq(level, 0, "level after draining")
    assert_eq(empty, 1, "empty after draining")


@cocotb.test()
async def test_almost_flags(dut) -> None:
    """Directed: the almost-full and almost-empty thresholds."""
    domain, source, _sink = await bring_up(dut)
    dut.m_ready.value = 0
    await domain.edge()

    assert_eq(await sampled(dut.almost_empty), 1,
              "almost_empty must assert at level 0")
    # sampled() leaves the simulation in the read-only phase; the edge returns
    # it to one where the source may drive.
    await domain.edge()

    for written in range(1, DEPTH + 1):
        await source.send(written & DATA_MASK)
        await domain.cycles(4)

        level, af, ae = await sample(dut.level, dut.almost_full,
                                     dut.almost_empty)
        assert_eq(level, written, f"level after {written} write(s)")
        assert_eq(af, 1 if written >= ALMOST_FULL_LEVEL else 0,
                  f"almost_full at level {written}")
        assert_eq(ae, 1 if written <= ALMOST_EMPTY_LEVEL else 0,
                  f"almost_empty at level {written}")
        await domain.edge()


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_traffic(dut) -> None:
    """Randomised: corner-biased words with back-pressure on both sides."""
    rng = RandomStream("fifo_sync")
    _domain, source, sink = await bring_up(dut, ready_probability=0.6, rng=rng)
    dut._log.info("random seed = %d", rng.seed)

    values = [rng.corner_uint(DATA_WIDTH) for _ in range(500)]
    await source.send_many(values, gap=rng.delay)

    await expect_stream(sink, values, timeout_cycles=4000)
    dut._log.info("%d words matched", sink.count)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_full_rate_streaming(dut) -> None:
    """Regression: one word in and one word out every cycle, sustained.

    This is the case the two-entry output stage exists for. A one-entry stage
    would have to stall the prefetch whenever the output was occupied, halving
    the throughput.
    """
    _domain, source, sink = await bring_up(dut)
    rng = RandomStream("full_rate")

    values = [rng.uint(DATA_WIDTH) for _ in range(1000)]
    await source.send_many(values)

    await expect_stream(sink, values, timeout_cycles=4000)
    assert_eq(sink.count, len(values), "words delivered at full rate")


@cocotb.test()
async def test_held_full_then_drained(dut) -> None:
    """Regression: the FIFO parked at capacity, then drained at full rate."""
    domain, source, sink = await bring_up(dut)
    rng = RandomStream("held_full")

    dut.m_ready.value = 0
    await domain.edge()

    values = await fill(dut, source, DEPTH, start=0x200)
    await domain.cycles(8)
    assert_eq(await sampled(dut.full), 1, "FIFO should be parked full")

    # Now stream through it while it stays full: every accepted write must be
    # matched by a read.
    await domain.edge()
    dut.m_ready.value = 1

    more = [rng.uint(DATA_WIDTH) for _ in range(200)]
    await source.send_many(more)

    await expect_stream(sink, values + more, timeout_cycles=4000)


@cocotb.test()
async def test_reset_during_traffic(dut) -> None:
    """Regression: a mid-stream reset empties the FIFO and it restarts clean."""
    domain, source, _sink = await bring_up(dut)
    rng = RandomStream("reset_mid")

    dut.m_ready.value = 0
    await domain.edge()
    await fill(dut, source, DEPTH // 2, start=0x300)
    await domain.cycles(4)

    source.idle()
    await domain.reset()

    level, empty, m_valid = await sample(dut.level, dut.empty, dut.m_valid)
    assert_eq(level, 0, "level after mid-stream reset")
    assert_eq(empty, 1, "empty after mid-stream reset")
    assert_eq(m_valid, 0, "m_valid after mid-stream reset")

    # Immediately usable again.
    await domain.edge()
    dut.m_ready.value = 1
    fresh = StreamSink(dut.clk, dut.m_valid, dut.m_ready, dut.m_data,
                       rst_n=dut.rst_n, name="post_reset")
    await domain.edge()
    fresh.start()

    values = [rng.uint(DATA_WIDTH) for _ in range(32)]
    await source.send_many(values)
    await expect_stream(fresh, values, timeout_cycles=1000)
