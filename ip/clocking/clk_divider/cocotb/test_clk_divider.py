"""Cocotb regression for clk_divider.

Coverage
    directed   parked state while disabled, clk_en rate, exact 50% duty cycle
               on the divided clock, enable and disable behaviour
    randomised enable toggled at random points, checking the enable pulse rate
               never drifts
    regression sustained run confirming the divided period does not accumulate
               error over hundreds of periods

The duty cycle is measured from real simulation timestamps rather than
inferred from a model. An odd divisor is the case that invites a duty cycle
wrong by half a source period, and only a measurement catches it.
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge
from cocotb.utils import get_sim_time

from socip import (
    ClockDomain,
    RandomStream,
    assert_eq,
    describe,
    get_param,
    sample,
    sampled,
)

DIVISOR = get_param("DIVISOR", 2)
CLK_PERIOD_NS = 10.0

# Half a divided period, in picoseconds. Exact for both parities: the block
# promises a true 50% duty cycle even when DIVISOR is odd.
HALF_PERIOD_PS = round(DIVISOR * CLK_PERIOD_NS * 1000 / 2)

# One picosecond of tolerance absorbs timescale rounding and nothing else.
TOLERANCE_PS = 2


async def bring_up(dut, enable: int = 1) -> ClockDomain:
    """Reset the divider and leave it in a known state."""
    dut._log.info("clk_divider: DIVISOR=%d, %s", DIVISOR, describe())
    dut.enable.value = 0
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    await domain.reset()
    dut.enable.value = enable
    return domain


async def count_enable_pulses(dut, cycles: int) -> int:
    """Count clk_en assertions over *cycles* source clock cycles."""
    pulses = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
        if await sampled(dut.clk_en):
            pulses += 1
    return pulses


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_parked_while_disabled(dut) -> None:
    """Directed: both outputs are parked while enable is low."""
    domain = await bring_up(dut, enable=0)
    await domain.cycles(4 * DIVISOR)

    clk_en, clk_out = await sample(dut.clk_en, dut.clk_out)
    assert_eq(clk_en, 0, "clk_en while disabled")
    if DIVISOR > 1:
        assert_eq(clk_out, 0, "clk_out while disabled")


@cocotb.test()
async def test_enable_rate(dut) -> None:
    """Directed: exactly one clk_en pulse per DIVISOR source cycles."""
    await bring_up(dut)
    await ClockCycles(dut.clk, 2 * DIVISOR)      # let the counter settle

    periods = 20
    pulses = await count_enable_pulses(dut, periods * DIVISOR)
    assert_eq(pulses, periods,
              f"clk_en pulses in {periods * DIVISOR} source cycles")


@cocotb.test()
async def test_duty_cycle(dut) -> None:
    """Directed: the divided clock is 50% duty, odd divisors included."""
    if DIVISOR == 1:
        dut._log.info("DIVISOR=1 passes the clock through; duty is the source's")
        return

    await bring_up(dut)

    # Skip the first period: it starts from the reset state and its low phase
    # is not representative.
    await RisingEdge(dut.clk_out)
    await RisingEdge(dut.clk_out)

    for period in range(12):
        rise = get_sim_time("ps")
        await FallingEdge(dut.clk_out)
        fall = get_sim_time("ps")
        await RisingEdge(dut.clk_out)
        next_rise = get_sim_time("ps")

        high = fall - rise
        low = next_rise - fall

        assert abs(high - HALF_PERIOD_PS) <= TOLERANCE_PS, (
            f"period {period}: high phase {high} ps, expected {HALF_PERIOD_PS} ps")
        assert abs(low - HALF_PERIOD_PS) <= TOLERANCE_PS, (
            f"period {period}: low phase {low} ps, expected {HALF_PERIOD_PS} ps")

    dut._log.info("duty cycle exact over 12 periods at DIVISOR=%d", DIVISOR)


@cocotb.test()
async def test_disable_parks_output(dut) -> None:
    """Directed: disabling mid-run parks the outputs and restarts cleanly."""
    domain = await bring_up(dut)
    await domain.cycles(4 * DIVISOR)

    dut.enable.value = 0
    await domain.cycles(2 * DIVISOR)
    clk_en, clk_out = await sample(dut.clk_en, dut.clk_out)
    assert_eq(clk_en, 0, "clk_en after disable")
    if DIVISOR > 1:
        assert_eq(clk_out, 0, "clk_out after disable")

    await domain.edge()
    dut.enable.value = 1
    await domain.cycles(2 * DIVISOR)

    pulses = await count_enable_pulses(dut, 10 * DIVISOR)
    assert_eq(pulses, 10, "clk_en rate after re-enable")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_enable_toggling(dut) -> None:
    """Randomised: the enable is toggled at random points in the period.

    Each enabled window must produce pulses at the correct rate. The divider
    restarts from zero on every enable, so a window of N*DIVISOR cycles
    always yields exactly N pulses.
    """
    rng = RandomStream("clk_divider")
    dut._log.info("random seed = %d", rng.seed)
    domain = await bring_up(dut, enable=0)

    for window in range(25):
        # Idle for a random time with the divider disabled.
        await domain.cycles(rng.between(1, 3 * DIVISOR))

        await domain.edge()
        dut.enable.value = 1
        # The counter restarts at zero, so the first pulse lands DIVISOR
        # cycles later; measure a whole number of periods from there.
        periods = rng.between(2, 6)
        pulses = await count_enable_pulses(dut, periods * DIVISOR)
        assert_eq(pulses, periods, f"window {window}: pulses in {periods} periods")

        await domain.edge()
        dut.enable.value = 0
        await domain.cycles(1)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_no_drift_over_long_run(dut) -> None:
    """Regression: the period does not accumulate error over a long run."""
    if DIVISOR == 1:
        dut._log.info("DIVISOR=1: no counter to drift")
        return

    await bring_up(dut)
    await RisingEdge(dut.clk_out)
    await RisingEdge(dut.clk_out)

    periods = 200
    start = get_sim_time("ps")
    for _ in range(periods):
        await RisingEdge(dut.clk_out)
    elapsed = get_sim_time("ps") - start

    expected = periods * 2 * HALF_PERIOD_PS
    assert abs(elapsed - expected) <= TOLERANCE_PS, (
        f"{periods} periods took {elapsed} ps, expected {expected} ps "
        f"(drift of {elapsed - expected} ps)")

    dut._log.info("no drift over %d periods at DIVISOR=%d", periods, DIVISOR)
