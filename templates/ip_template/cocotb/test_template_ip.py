"""Cocotb regression for template_ip.

Test classes, in the order every IP in the portfolio provides them:

* directed   - named cases for the corners of the specification
* randomised - constrained-random traffic against a reference model
* regression - long runs and a permanent case for every bug ever found

The ready/valid handshake is driven and observed through the shared
transactors in ``socip.stream``, which sample in the ``ReadOnly`` phase. A
testbench that reads handles directly after a clock edge samples values that
are still settling and reports failures that depend on simulator scheduling
rather than on the design.
"""
from __future__ import annotations

import cocotb

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

# Elaboration parameters the model was built with. Never hard-code a width the
# RTL parameterises: the same test must pass at every supported configuration.
DATA_WIDTH = get_param("DATA_WIDTH", 8)

CLK_PERIOD_NS = 10.0
DATA_MASK = (1 << DATA_WIDTH) - 1


async def setup(dut, ready_probability: float = 1.0,
                rng: RandomStream | None = None
                ) -> tuple[ClockDomain, StreamSource, StreamSink]:
    """Bring the DUT up in a known state and return its clock and transactors."""
    dut._log.info("template_ip: DATA_WIDTH=%d, %s", DATA_WIDTH, describe())

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


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: the output stream is idle and the input is open out of reset."""
    await setup(dut)
    m_valid, s_ready = await sample(dut.m_valid, dut.s_ready)
    assert_eq(m_valid, 0, "m_valid after reset")
    assert_eq(s_ready, 1, "s_ready after reset")


@cocotb.test()
async def test_single_transfer(dut) -> None:
    """Directed: one word in, the same word out."""
    domain, source, sink = await setup(dut)

    await source.send(0xA5 & DATA_MASK)
    await domain.cycles(4)

    await expect_stream(sink, [0xA5 & DATA_MASK])
    assert_eq(sink.count, 1, "transfers observed")


@cocotb.test()
async def test_back_to_back(dut) -> None:
    """Directed: full-rate traffic with no idle cycles between transfers."""
    domain, source, sink = await setup(dut)

    values = [i & DATA_MASK for i in range(16)]
    await source.send_many(values)
    await domain.cycles(8)

    await expect_stream(sink, values)


@cocotb.test()
async def test_sink_backpressure(dut) -> None:
    """Directed: the payload is held while the sink withholds ready."""
    domain, source, _sink = await setup(dut)

    # Drive the sink by hand here: the point of the test is to hold ready low
    # for a known number of cycles and prove nothing moves or changes.
    dut.m_ready.value = 0
    await source.send(0x3C & DATA_MASK)

    held_valid, held_data, s_ready = await sample(
        dut.m_valid, dut.m_data, dut.s_ready)
    assert_eq(held_valid, 1, "m_valid asserted once the word is registered")
    assert_eq(held_data, 0x3C & DATA_MASK, "registered payload")
    # With the output occupied and the sink stalled, the input must close.
    assert_eq(s_ready, 0, "s_ready withdrawn while stalled")

    for cycle in range(5):
        await domain.edge()
        stalled_valid, stalled_data = await sample(dut.m_valid, dut.m_data)
        assert_eq(stalled_valid, 1, f"m_valid held at stall cycle {cycle}")
        assert_eq(stalled_data, held_data, f"m_data held at stall cycle {cycle}")

    # Releasing back-pressure drains the word and reopens the input. The edge
    # first leaves the read-only phase that sample() left the simulation in.
    await domain.edge()
    dut.m_ready.value = 1
    await domain.cycles(2)
    drained_valid, drained_ready = await sample(dut.m_valid, dut.s_ready)
    assert_eq(drained_valid, 0, "m_valid cleared after drain")
    assert_eq(drained_ready, 1, "s_ready reopened after drain")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_traffic(dut) -> None:
    """Randomised: corner-biased payloads with random sink back-pressure."""
    rng = RandomStream("template_ip")
    domain, source, sink = await setup(dut, ready_probability=0.75, rng=rng)
    dut._log.info("random seed = %d", rng.seed)

    values = [rng.corner_uint(DATA_WIDTH) for _ in range(400)]
    await source.send_many(values, gap=rng.delay)
    await domain.cycles(32)

    await expect_stream(sink, values)
    dut._log.info("%s: %d transfers matched", sink.name, sink.count)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_during_traffic(dut) -> None:
    """Regression: a mid-stream reset returns the block to the idle state."""
    domain, source, sink = await setup(dut)
    rng = RandomStream("reset_mid")

    await source.send_many(rng.uint(DATA_WIDTH) for _ in range(8))

    source.idle()
    await domain.reset()
    assert_eq(await sampled(dut.m_valid), 0, "m_valid after mid-stream reset")

    # The block must be immediately usable again after reset. The edge leaves
    # the read-only phase that sampled() left the simulation in.
    await domain.edge()
    baseline = sink.count
    await source.send(0x5A & DATA_MASK)
    await domain.cycles(4)

    assert_eq(sink.count - baseline, 1, "one transfer completed after reset")
    assert_eq(sink.received[-1], 0x5A & DATA_MASK, "payload after reset")


@cocotb.test()
async def test_long_run(dut) -> None:
    """Regression: sustained traffic, checking nothing drifts over time."""
    rng = RandomStream("long_run")
    domain, source, sink = await setup(dut)
    dut._log.info("random seed = %d", rng.seed)

    values = [rng.uint(DATA_WIDTH) for _ in range(2000)]
    await source.send_many(values)
    await domain.cycles(16)

    await expect_stream(sink, values)
    assert_eq(sink.count, 2000, "transfers completed")
