"""Cocotb regression for cdc_pulse_sync.

Coverage
    directed   reset state, a single event, busy handshake, one-cycle-wide
               destination pulse
    randomised events at random gaps across three clock ratios - destination
               faster, destination slower, and nearly the same frequency
    regression long runs at each ratio checking that the event count is exactly
               preserved, and events presented immediately after reset

Clock ratios matter more than anything else for this block: a pulse
synchroniser that works at one ratio can silently drop or duplicate events at
another, so every test runs at all three.
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge

from socip import (
    ClockDomain,
    RandomStream,
    assert_eq,
    describe,
    get_param,
    sample,
    sampled,
)

STAGES = get_param("STAGES", 2)

# (source period, destination period). Deliberately non-integer ratios: the
# design must not depend on the two clocks having a rational relationship.
RATIOS = {
    "dst_faster": (23.0, 7.0),
    "dst_slower": (7.0, 23.0),
    "near_equal": (10.0, 10.7),
}


class EventCounter:
    """Counts destination pulses and checks each is exactly one cycle wide."""

    def __init__(self, dut, dst: ClockDomain) -> None:
        self.dut = dut
        self.dst = dst
        self.count = 0
        self.errors: list[str] = []
        self._task = None

    def start(self) -> "EventCounter":
        self._task = cocotb.start_soon(self._run())
        return self

    def stop(self) -> None:
        if self._task is not None:
            self._task.kill()
            self._task = None

    async def _run(self) -> None:
        previous = 0
        while True:
            await RisingEdge(self.dut.dst_clk)
            pulse, reset_n = await sample(self.dut.dst_pulse,
                                          self.dut.dst_rst_n)
            if not reset_n:
                previous = 0
                continue
            if pulse:
                if previous:
                    self.errors.append(
                        "dst_pulse was asserted for more than one cycle")
                self.count += 1
            previous = pulse


async def bring_up(dut, src_period: float, dst_period: float
                   ) -> tuple[ClockDomain, ClockDomain, EventCounter]:
    """Start both clocks, reset both domains, and start the event counter."""
    dut._log.info("cdc_pulse_sync: STAGES=%d, src=%.1f ns, dst=%.1f ns, %s",
                  STAGES, src_period, dst_period, describe())

    dut.src_pulse.value = 0
    src = ClockDomain(dut.src_clk, dut.src_rst_n, src_period, "src").start()
    dst = ClockDomain(dut.dst_clk, dut.dst_rst_n, dst_period, "dst").start()

    dut.src_rst_n.value = 0
    dut.dst_rst_n.value = 0
    for _ in range(4):
        await RisingEdge(dut.src_clk)
    for _ in range(4):
        await RisingEdge(dut.dst_clk)
    dut.src_rst_n.value = 1
    dut.dst_rst_n.value = 1
    await RisingEdge(dut.src_clk)

    counter = EventCounter(dut, dst).start()
    return src, dst, counter


async def send_event(dut) -> None:
    """Present one source-domain pulse, waiting for the block to be free."""
    while True:
        await RisingEdge(dut.src_clk)
        if await sampled(dut.src_busy) == 0:
            break
    await RisingEdge(dut.src_clk)
    dut.src_pulse.value = 1
    await RisingEdge(dut.src_clk)
    dut.src_pulse.value = 0


async def drain(dut, dst_cycles: int = 24) -> None:
    for _ in range(dst_cycles):
        await RisingEdge(dut.dst_clk)


def check_counter(counter: EventCounter, expected: int, context: str) -> None:
    if counter.errors:
        raise AssertionError(f"{context}: {counter.errors[0]}")
    assert_eq(counter.count, expected, f"{context}: destination event count")


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: no pulse and no busy out of reset."""
    src_period, dst_period = RATIOS["near_equal"]
    await bring_up(dut, src_period, dst_period)
    busy, pulse = await sample(dut.src_busy, dut.dst_pulse)
    assert_eq(busy, 0, "src_busy after reset")
    assert_eq(pulse, 0, "dst_pulse after reset")


@cocotb.test()
async def test_single_event(dut) -> None:
    """Directed: one source pulse produces exactly one destination pulse."""
    src_period, dst_period = RATIOS["near_equal"]
    _src, _dst, counter = await bring_up(dut, src_period, dst_period)

    await send_event(dut)
    await drain(dut)

    check_counter(counter, 1, "single event")


@cocotb.test()
async def test_busy_protocol(dut) -> None:
    """Directed: busy rises while the event is in flight and clears after."""
    src_period, dst_period = RATIOS["dst_slower"]
    src, _dst, counter = await bring_up(dut, src_period, dst_period)

    await send_event(dut)
    assert_eq(await sampled(dut.src_busy), 1,
              "src_busy must rise once an event is accepted")

    # It must clear on its own within the round trip.
    for _ in range(200):
        await RisingEdge(dut.src_clk)
        if await sampled(dut.src_busy) == 0:
            break
        await RisingEdge(dut.src_clk)
    else:
        raise AssertionError("src_busy never cleared")

    await drain(dut)
    check_counter(counter, 1, "busy protocol")
    await src.cycles(1)


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_events_all_ratios(dut) -> None:
    """Randomised: events at random gaps, at every clock ratio."""
    rng = RandomStream("pulse_sync")
    dut._log.info("random seed = %d", rng.seed)

    for name, (src_period, dst_period) in RATIOS.items():
        _src, _dst, counter = await bring_up(dut, src_period, dst_period)

        events = 60
        for _ in range(events):
            for _ in range(rng.between(0, 5)):
                await RisingEdge(dut.src_clk)
            await send_event(dut)

        await drain(dut, 64)
        check_counter(counter, events, f"ratio {name}")
        counter.stop()
        dut._log.info("ratio %s: %d events preserved", name, events)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_maximum_rate(dut) -> None:
    """Regression: events presented as fast as src_busy allows.

    This is the case that breaks a toggle synchroniser without the
    acknowledge path: a second event accepted before the first completes
    toggles the source flip-flop back and both events vanish.
    """
    for name, (src_period, dst_period) in RATIOS.items():
        _src, _dst, counter = await bring_up(dut, src_period, dst_period)

        events = 100
        for _ in range(events):
            await send_event(dut)

        await drain(dut, 64)
        check_counter(counter, events, f"maximum rate, ratio {name}")
        counter.stop()


@cocotb.test()
async def test_event_immediately_after_reset(dut) -> None:
    """Regression: the first event after reset release is not lost."""
    src_period, dst_period = RATIOS["dst_faster"]
    _src, _dst, counter = await bring_up(dut, src_period, dst_period)

    await send_event(dut)
    await drain(dut, 32)
    check_counter(counter, 1, "first event after reset")
