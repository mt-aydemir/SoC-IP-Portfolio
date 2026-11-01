"""Cocotb regression for clk_gate.

Coverage
    directed   no edges while disabled, one gated edge per source edge while
               enabled, test_en forcing the gate open
    randomised the enable changed at random points inside the clock period,
               including the middle of the high phase, which is precisely
               where a naive AND gate produces a runt
    regression a long randomised run in which every single gated pulse is
               measured, so one runt anywhere fails the test

The measurement is the point. A functional check that counts edges would pass
on a naive AND gate; only measuring the width of every pulse distinguishes a
correct clock gate from a broken one.
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

from socip import RandomStream, assert_eq, describe, start_clock

CLK_PERIOD_NS = 10.0
HIGH_PHASE_PS = round(CLK_PERIOD_NS * 1000 / 2)
TOLERANCE_PS = 2


class PulseMonitor:
    """Measures every high phase of the gated clock and flags any runt."""

    def __init__(self, dut) -> None:
        self.dut = dut
        self.pulses = 0
        self.rises = 0
        self.errors: list[str] = []
        self._task = None

    def start(self) -> "PulseMonitor":
        self._task = cocotb.start_soon(self._run())
        return self

    def stop(self) -> None:
        if self._task is not None:
            self._task.kill()
            self._task = None

    async def _run(self) -> None:
        while True:
            await RisingEdge(self.dut.gated_clk)
            rise = get_sim_time("ps")
            self.rises += 1

            # The gated clock may only rise while the source clock is high.
            if int(self.dut.clk.value) != 1:
                self.errors.append(
                    f"gated_clk rose while clk was low at {rise} ps")

            await FallingEdge(self.dut.gated_clk)
            width = get_sim_time("ps") - rise
            self.pulses += 1
            if abs(width - HIGH_PHASE_PS) > TOLERANCE_PS:
                self.errors.append(
                    f"runt pulse of {width} ps at {rise} ps, "
                    f"expected {HIGH_PHASE_PS} ps")

    def check(self, context: str) -> None:
        if self.errors:
            raise AssertionError(f"{context}: {self.errors[0]} "
                                 f"({len(self.errors)} problem(s) total)")


async def bring_up(dut) -> PulseMonitor:
    """Start the source clock with the gate closed."""
    dut._log.info("clk_gate: %s", describe())
    dut.enable.value = 0
    dut.test_en.value = 0
    start_clock(dut.clk, CLK_PERIOD_NS)
    await RisingEdge(dut.clk)
    return PulseMonitor(dut).start()


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_no_edges_while_disabled(dut) -> None:
    """Directed: the gated clock is completely still while disabled."""
    monitor = await bring_up(dut)
    for _ in range(20):
        await RisingEdge(dut.clk)

    assert_eq(monitor.rises, 0, "gated clock edges while disabled")
    assert_eq(dut.gated_clk.value, 0, "gated_clk level while disabled")
    monitor.check("disabled")


@cocotb.test()
async def test_one_edge_per_source_edge(dut) -> None:
    """Directed: with the gate open, every source edge appears at the output."""
    monitor = await bring_up(dut)

    await FallingEdge(dut.clk)
    dut.enable.value = 1
    monitor.rises = 0

    for _ in range(20):
        await RisingEdge(dut.clk)
    await Timer(1, units="ns")

    assert_eq(monitor.rises, 20, "gated edges with the gate open")
    monitor.check("enabled")


@cocotb.test()
async def test_test_enable_forces_gate_open(dut) -> None:
    """Directed: test_en clocks the design regardless of the functional enable."""
    monitor = await bring_up(dut)

    await FallingEdge(dut.clk)
    dut.enable.value = 0
    dut.test_en.value = 1
    monitor.rises = 0

    for _ in range(10):
        await RisingEdge(dut.clk)
    await Timer(1, units="ns")

    assert_eq(monitor.rises, 10, "gated edges with test_en asserted")
    monitor.check("test_en")


@cocotb.test()
async def test_enable_change_mid_high_phase(dut) -> None:
    """Directed: changing the enable mid-high-phase must not chop the pulse.

    This is the case a naive ``clk & enable`` gets wrong. The enable is
    produced by rising-edge logic, so it settles shortly after the clock rises
    — right in the middle of the high phase.
    """
    monitor = await bring_up(dut)

    for _ in range(30):
        await RisingEdge(dut.clk)
        await Timer(round(CLK_PERIOD_NS * 1000 / 4), units="ps")
        dut.enable.value = 0 if int(dut.enable.value) else 1

    dut.enable.value = 1
    for _ in range(4):
        await RisingEdge(dut.clk)

    monitor.check("enable changed mid-high-phase")
    assert monitor.pulses > 5, "the test did not actually open the gate"


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_enable_phases(dut) -> None:
    """Randomised: the enable changes at random points inside the period."""
    rng = RandomStream("clk_gate")
    dut._log.info("random seed = %d", rng.seed)
    monitor = await bring_up(dut)

    for _ in range(300):
        await RisingEdge(dut.clk)
        offset = rng.between(1, 9) * round(CLK_PERIOD_NS * 1000 / 10)
        await Timer(offset, units="ps")
        dut.enable.value = int(rng.boolean(0.5))

    dut.enable.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)

    monitor.check("randomised enable")
    dut._log.info("%d pulses measured, none runt", monitor.pulses)
    assert monitor.pulses > 50, "the randomised run produced too few pulses"


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_long_run_all_pulses_measured(dut) -> None:
    """Regression: a long run with every pulse width checked."""
    rng = RandomStream("clk_gate_long")
    monitor = await bring_up(dut)

    for _ in range(1000):
        await RisingEdge(dut.clk)
        if rng.boolean(0.15):
            await Timer(rng.between(1, 9) * round(CLK_PERIOD_NS * 100),
                        units="ps")
            dut.enable.value = int(rng.boolean(0.6))

    dut.enable.value = 0
    for _ in range(4):
        await RisingEdge(dut.clk)

    monitor.check("long run")
    dut._log.info("%d pulses measured over the long run", monitor.pulses)
    assert monitor.pulses > 300, "the long run produced too few pulses"
