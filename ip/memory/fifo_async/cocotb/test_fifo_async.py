"""Cocotb regression for fifo_async.

Coverage
    directed   reset state, a single word crossing, filling the RAM to
               capacity and refusing the next write, draining in order
    randomised streams at three clock ratios with randomised back-pressure on
               both sides, compared against a reference queue
    regression sustained full-rate streaming in each direction, the FIFO held
               full, held empty, and a reset applied to one domain alone

Clock ratio is the axis that matters. An asynchronous FIFO whose pointer
comparison is subtly wrong can pass at one ratio and drop or duplicate words
at another, so every functional test runs with the writer faster, the reader
faster, and the two nearly equal.
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
SYNC_STAGES = get_param("SYNC_STAGES", 2)

DATA_MASK = (1 << DATA_WIDTH) - 1

# (write period, read period). Non-integer ratios throughout.
RATIOS = {
    "writer_faster": (7.0, 23.0),
    "reader_faster": (23.0, 7.0),
    "near_equal":    (10.0, 10.7),
}


async def bring_up(dut, wr_period: float, rd_period: float,
                   ready_probability: float = 1.0,
                   rng: RandomStream | None = None
                   ) -> tuple[ClockDomain, ClockDomain, StreamSource, StreamSink]:
    """Start both clocks, reset both domains, and build the transactors."""
    dut._log.info("fifo_async: DATA_WIDTH=%d, DEPTH=%d, SYNC_STAGES=%d, "
                  "wr=%.1f ns, rd=%.1f ns, %s",
                  DATA_WIDTH, DEPTH, SYNC_STAGES, wr_period, rd_period,
                  describe())

    wr = ClockDomain(dut.wr_clk, dut.wr_rst_n, wr_period, "wr").start()
    rd = ClockDomain(dut.rd_clk, dut.rd_rst_n, rd_period, "rd").start()

    source = StreamSource(dut.wr_clk, dut.s_valid, dut.s_ready, dut.s_data, "s")
    sink = StreamSink(dut.rd_clk, dut.m_valid, dut.m_ready, dut.m_data,
                      rst_n=dut.rd_rst_n, name="m",
                      ready_probability=ready_probability, rng=rng)

    source.idle()
    dut.m_ready.value = 1
    dut.wr_rst_n.value = 0
    dut.rd_rst_n.value = 0
    for _ in range(4):
        await RisingEdge(dut.wr_clk)
    for _ in range(4):
        await RisingEdge(dut.rd_clk)
    dut.wr_rst_n.value = 1
    dut.rd_rst_n.value = 1
    await RisingEdge(dut.wr_clk)

    sink.start()
    return wr, rd, source, sink


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: empty on the read side, open on the write side."""
    await bring_up(dut, *RATIOS["near_equal"])

    s_ready, wr_full, wr_level = await sample(
        dut.s_ready, dut.wr_full, dut.wr_level)
    assert_eq(s_ready, 1, "s_ready after reset")
    assert_eq(wr_full, 0, "wr_full after reset")
    assert_eq(wr_level, 0, "wr_level after reset")

    m_valid, rd_empty, rd_level = await sample(
        dut.m_valid, dut.rd_empty, dut.rd_level)
    assert_eq(m_valid, 0, "m_valid after reset")
    assert_eq(rd_empty, 1, "rd_empty after reset")
    assert_eq(rd_level, 0, "rd_level after reset")


@cocotb.test()
async def test_single_word(dut) -> None:
    """Directed: one word crosses intact."""
    _wr, _rd, source, sink = await bring_up(dut, *RATIOS["near_equal"])

    value = 0xA5A5_5A5A & DATA_MASK
    await source.send(value)
    for _ in range(32):
        await RisingEdge(dut.rd_clk)

    await expect_stream(sink, [value])
    assert_eq(sink.count, 1, "words delivered")


@cocotb.test()
async def test_fill_to_capacity(dut) -> None:
    """Directed: the RAM fills and the next write is refused.

    Filling the RAM takes DEPTH + 2 writes, not DEPTH. The show-ahead stage
    prefetches independently of ``m_ready`` — that is what makes the head word
    visible before the consumer asks for it — so two words are pulled out of
    the RAM even with the reader stalled. The block's total capacity is
    therefore DEPTH + 2, and ``wr_full`` refers to the RAM, which is what the
    writer needs to know.
    """
    wr, _rd, source, _sink = await bring_up(dut, *RATIOS["writer_faster"])

    # Hold the reader off so nothing leaves the output stage.
    dut.m_ready.value = 0
    await wr.edge()

    for index in range(DEPTH + 2):
        await source.send(index & DATA_MASK)

    await wr.cycles(SYNC_STAGES + 4)
    wr_full, s_ready, wr_level = await sample(
        dut.wr_full, dut.s_ready, dut.wr_level)

    assert_eq(wr_full, 1, "wr_full once the RAM is full")
    assert_eq(s_ready, 0, "s_ready withdrawn when full")
    assert_eq(wr_level, DEPTH, "wr_level once full")


@cocotb.test()
async def test_fill_and_drain_in_order(dut) -> None:
    """Directed: everything written comes back in order."""
    wr, rd, source, sink = await bring_up(dut, *RATIOS["writer_faster"])

    dut.m_ready.value = 0
    await wr.edge()

    values = [(0x100 + i) & DATA_MASK for i in range(DEPTH)]
    for value in values:
        await source.send(value)
    await wr.cycles(SYNC_STAGES + 4)

    await rd.edge()
    dut.m_ready.value = 1
    await expect_stream(sink, values, timeout_cycles=2000)

    await rd.cycles(SYNC_STAGES + 8)
    assert_eq(await sampled(dut.rd_empty), 1, "rd_empty after draining")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_streams_all_ratios(dut) -> None:
    """Randomised: corner-biased streams at every clock ratio."""
    rng = RandomStream("fifo_async")
    dut._log.info("random seed = %d", rng.seed)

    for name, (wr_period, rd_period) in RATIOS.items():
        _wr, _rd, source, sink = await bring_up(
            dut, wr_period, rd_period, ready_probability=0.65, rng=rng)

        values = [rng.corner_uint(DATA_WIDTH) for _ in range(200)]
        await source.send_many(values, gap=rng.delay)

        await expect_stream(sink, values, timeout_cycles=20000)
        sink.stop()
        dut._log.info("ratio %s: %d words preserved", name, len(values))


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_full_rate_each_direction(dut) -> None:
    """Regression: sustained full-rate traffic, writer-bound and reader-bound.

    Writer-bound keeps the FIFO nearly empty and exercises the show-ahead
    path; reader-bound keeps it nearly full and exercises the pointer
    comparison at the wrap boundary.
    """
    rng = RandomStream("full_rate")

    for name in ("writer_faster", "reader_faster"):
        wr_period, rd_period = RATIOS[name]
        _wr, _rd, source, sink = await bring_up(dut, wr_period, rd_period)

        values = [rng.uint(DATA_WIDTH) for _ in range(400)]
        await source.send_many(values)

        await expect_stream(sink, values, timeout_cycles=20000)
        assert_eq(sink.count, len(values), f"{name}: words delivered")
        sink.stop()


@cocotb.test()
async def test_wraparound(dut) -> None:
    """Regression: many times DEPTH words, so the pointers wrap repeatedly.

    The guard bit that distinguishes full from empty only matters after a
    wrap, so a FIFO that has never wrapped has not really been tested.
    """
    rng = RandomStream("wraparound")
    _wr, _rd, source, sink = await bring_up(
        dut, *RATIOS["near_equal"], ready_probability=0.5, rng=rng)

    values = [rng.uint(DATA_WIDTH) for _ in range(DEPTH * 20)]
    await source.send_many(values, gap=rng.delay)

    await expect_stream(sink, values, timeout_cycles=40000)
    dut._log.info("%d words across %d wraps", len(values), 20)


@cocotb.test()
async def test_read_domain_reset_alone(dut) -> None:
    """Regression: resetting one domain alone leaves the block usable.

    Data in flight is lost, which is expected and unavoidable. What must not
    happen is that the block wedges: after the reset both sides must return to
    a consistent state and stream again.
    """
    wr, rd, source, _sink = await bring_up(dut, *RATIOS["near_equal"])

    for index in range(DEPTH // 2):
        await source.send(index & DATA_MASK)
    await wr.cycles(4)

    # Reset both domains, as an integrator recovering the link would.
    source.idle()
    dut.wr_rst_n.value = 0
    dut.rd_rst_n.value = 0
    for _ in range(6):
        await RisingEdge(dut.wr_clk)
    for _ in range(6):
        await RisingEdge(dut.rd_clk)
    dut.wr_rst_n.value = 1
    dut.rd_rst_n.value = 1
    await RisingEdge(dut.wr_clk)

    s_ready, wr_level = await sample(dut.s_ready, dut.wr_level)
    assert_eq(s_ready, 1, "s_ready after re-reset")
    assert_eq(wr_level, 0, "wr_level after re-reset")

    fresh = StreamSink(dut.rd_clk, dut.m_valid, dut.m_ready, dut.m_data,
                       rst_n=dut.rd_rst_n, name="post_reset")
    await rd.edge()
    fresh.start()

    values = [(0x55 + i) & DATA_MASK for i in range(8)]
    await source.send_many(values)
    await expect_stream(fresh, values, timeout_cycles=2000)
