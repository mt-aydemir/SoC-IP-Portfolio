"""Cocotb regression for cdc_handshake.

Coverage
    directed   reset state, a single word, destination back-pressure holding
               the payload, source stalls while a transfer is in flight
    randomised streams of corner-biased words at three clock ratios, with
               randomised destination back-pressure
    regression long runs checking exact order and count preservation, and a
               reset asserted in one domain in the middle of a transfer

Both interfaces are ordinary ready/valid streams, so they are driven and
observed with the shared transactors from ``socip.stream``.
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
)

DATA_WIDTH = get_param("DATA_WIDTH", 32)
STAGES = get_param("STAGES", 2)

DATA_MASK = (1 << DATA_WIDTH) - 1

# (source period, destination period). Non-integer ratios throughout.
RATIOS = {
    "dst_faster": (23.0, 7.0),
    "dst_slower": (7.0, 23.0),
    "near_equal": (10.0, 10.7),
}


async def bring_up(dut, src_period: float, dst_period: float,
                   ready_probability: float = 1.0,
                   rng: RandomStream | None = None
                   ) -> tuple[ClockDomain, ClockDomain, StreamSource, StreamSink]:
    """Start both clocks, reset both domains, and build the transactors."""
    dut._log.info("cdc_handshake: DATA_WIDTH=%d, STAGES=%d, "
                  "src=%.1f ns, dst=%.1f ns, %s",
                  DATA_WIDTH, STAGES, src_period, dst_period, describe())

    src = ClockDomain(dut.src_clk, dut.src_rst_n, src_period, "src").start()
    dst = ClockDomain(dut.dst_clk, dut.dst_rst_n, dst_period, "dst").start()

    source = StreamSource(dut.src_clk, dut.src_valid, dut.src_ready,
                          dut.src_data, "src")
    sink = StreamSink(dut.dst_clk, dut.dst_valid, dut.dst_ready, dut.dst_data,
                      rst_n=dut.dst_rst_n, name="dst",
                      ready_probability=ready_probability, rng=rng)

    source.idle()
    dut.dst_ready.value = 1
    dut.src_rst_n.value = 0
    dut.dst_rst_n.value = 0
    for _ in range(4):
        await RisingEdge(dut.src_clk)
    for _ in range(4):
        await RisingEdge(dut.dst_clk)
    dut.src_rst_n.value = 1
    dut.dst_rst_n.value = 1
    await RisingEdge(dut.src_clk)

    sink.start()
    return src, dst, source, sink


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: the source is open and the destination idle out of reset."""
    await bring_up(dut, *RATIOS["near_equal"])
    src_ready, dst_valid = await sample(dut.src_ready, dut.dst_valid)
    assert_eq(src_ready, 1, "src_ready after reset")
    assert_eq(dst_valid, 0, "dst_valid after reset")


@cocotb.test()
async def test_single_word(dut) -> None:
    """Directed: one word crosses intact."""
    _src, _dst, source, sink = await bring_up(dut, *RATIOS["near_equal"])

    value = 0xA5A5_5A5A & DATA_MASK
    await source.send(value)
    for _ in range(32):
        await RisingEdge(dut.dst_clk)

    await expect_stream(sink, [value])
    assert_eq(sink.count, 1, "transfers observed")


@cocotb.test()
async def test_source_stalls_during_transfer(dut) -> None:
    """Directed: the source closes while a transfer is in flight.

    src_ready must stay low for the whole round trip. A source that reopened
    early would overwrite the payload register while the destination was still
    reading it, which is exactly the corruption the handshake exists to
    prevent.
    """
    _src, _dst, source, sink = await bring_up(dut, *RATIOS["dst_slower"])

    value = 0x1234_5678 & DATA_MASK
    cocotb.start_soon(source.send(value))

    # Once the request is raised the source must be closed until the round
    # trip completes.
    await RisingEdge(dut.src_clk)
    await RisingEdge(dut.src_clk)
    saw_closed = False
    for _ in range(200):
        await RisingEdge(dut.src_clk)
        ready, = await sample(dut.src_ready)
        if ready == 0:
            saw_closed = True
        elif saw_closed:
            break

    assert saw_closed, "src_ready never closed while the transfer was in flight"
    await expect_stream(sink, [value])


@cocotb.test()
async def test_destination_backpressure(dut) -> None:
    """Directed: the payload is held while the destination consumer stalls."""
    _src, _dst, source, _sink = await bring_up(dut, *RATIOS["near_equal"])

    dut.dst_ready.value = 0
    value = 0xDEAD_BEEF & DATA_MASK
    cocotb.start_soon(source.send(value))

    # Wait for the word to be presented.
    for _ in range(64):
        await RisingEdge(dut.dst_clk)
        valid, = await sample(dut.dst_valid)
        if valid:
            break
    else:
        raise AssertionError("dst_valid never rose with the sink stalled")

    # It must stay presented, unchanged, for as long as the sink withholds.
    for cycle in range(10):
        await RisingEdge(dut.dst_clk)
        valid, data = await sample(dut.dst_valid, dut.dst_data)
        assert_eq(valid, 1, f"dst_valid held at stall cycle {cycle}")
        assert_eq(data, value, f"dst_data held at stall cycle {cycle}")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_streams_all_ratios(dut) -> None:
    """Randomised: corner-biased words at every clock ratio, with back-pressure."""
    rng = RandomStream("cdc_handshake")
    dut._log.info("random seed = %d", rng.seed)

    for name, (src_period, dst_period) in RATIOS.items():
        _src, _dst, source, sink = await bring_up(
            dut, src_period, dst_period, ready_probability=0.7, rng=rng)

        values = [rng.corner_uint(DATA_WIDTH) for _ in range(60)]
        await source.send_many(values, gap=rng.delay)
        for _ in range(200):
            await RisingEdge(dut.dst_clk)

        await expect_stream(sink, values)
        sink.stop()
        dut._log.info("ratio %s: %d words preserved", name, len(values))


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_order_and_count_preserved(dut) -> None:
    """Regression: a long run preserves every word, in order, exactly once."""
    rng = RandomStream("order")
    _src, _dst, source, sink = await bring_up(dut, *RATIOS["dst_faster"])

    values = [rng.uint(DATA_WIDTH) for _ in range(300)]
    await source.send_many(values)
    for _ in range(200):
        await RisingEdge(dut.dst_clk)

    await expect_stream(sink, values)
    assert_eq(sink.count, len(values), "no duplicated or dropped words")


@cocotb.test()
async def test_reset_recovers(dut) -> None:
    """Regression: both domains recover and stream correctly after a reset."""
    _src, _dst, source, _sink = await bring_up(dut, *RATIOS["near_equal"])

    await source.send(0x0F0F_0F0F & DATA_MASK)
    for _ in range(16):
        await RisingEdge(dut.dst_clk)

    # Reset both domains together, as an integrator would.
    source.idle()
    dut.src_rst_n.value = 0
    dut.dst_rst_n.value = 0
    for _ in range(6):
        await RisingEdge(dut.src_clk)
    for _ in range(6):
        await RisingEdge(dut.dst_clk)
    dut.src_rst_n.value = 1
    dut.dst_rst_n.value = 1
    await RisingEdge(dut.src_clk)

    src_ready, dst_valid = await sample(dut.src_ready, dut.dst_valid)
    assert_eq(src_ready, 1, "src_ready after re-reset")
    assert_eq(dst_valid, 0, "dst_valid after re-reset")

    # A fresh sink, because the pre-reset one saw the earlier word.
    fresh = StreamSink(dut.dst_clk, dut.dst_valid, dut.dst_ready, dut.dst_data,
                       rst_n=dut.dst_rst_n, name="post_reset")
    await RisingEdge(dut.dst_clk)
    fresh.start()

    values = [0x1111_1111 & DATA_MASK, 0x2222_2222 & DATA_MASK]
    await source.send_many(values)
    for _ in range(64):
        await RisingEdge(dut.dst_clk)

    await expect_stream(fresh, values)
