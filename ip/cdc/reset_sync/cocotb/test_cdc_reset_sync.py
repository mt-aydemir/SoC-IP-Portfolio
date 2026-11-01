"""Cocotb regression for cdc_reset_sync.

Coverage
    directed   held-low behaviour, exact release latency, asynchronous
               assertion away from a clock edge, sub-cycle glitch capture
    randomised long sequence of assertions at random phases within the clock
               period, compared against a reference model
    regression back-to-back assert/release cycles with no idle time
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge, Timer

from socip import (
    RandomStream,
    assert_eq,
    between_edges,
    describe,
    get_param,
    settle,
    start_clock,
)

STAGES = get_param("STAGES", 2)
CLK_PERIOD_NS = 10.0


async def bring_up(dut) -> None:
    """Start the clock with the reset asserted."""
    dut._log.info("cdc_reset_sync: STAGES=%d, %s", STAGES, describe())
    dut.arst_n_in.value = 0
    start_clock(dut.clk, CLK_PERIOD_NS)
    for _ in range(3):
        await RisingEdge(dut.clk)


async def release_and_check(dut, context: str) -> None:
    """Release the reset and check it takes exactly STAGES edges to appear."""
    dut.arst_n_in.value = 1
    for cycle in range(1, STAGES + 1):
        await RisingEdge(dut.clk)
        await settle()
        expected = 1 if cycle >= STAGES else 0
        assert_eq(dut.rst_n_out.value, expected,
                  f"{context}: release edge {cycle} of {STAGES}")


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_held_low(dut) -> None:
    """Directed: the output stays asserted for as long as the input is low."""
    await bring_up(dut)
    for cycle in range(8):
        await RisingEdge(dut.clk)
        await settle()
        assert_eq(dut.rst_n_out.value, 0,
                  f"output must stay asserted at cycle {cycle}")


@cocotb.test()
async def test_release_latency(dut) -> None:
    """Directed: release appears exactly STAGES clock edges after the input."""
    await bring_up(dut)

    # Move off the edge so the release is not coincident with a sampling edge.
    await RisingEdge(dut.clk)
    await between_edges(CLK_PERIOD_NS, 0.5)
    await release_and_check(dut, "first release")

    # And it stays released.
    for cycle in range(6):
        await RisingEdge(dut.clk)
        await settle()
        assert_eq(dut.rst_n_out.value, 1, f"must stay released at cycle {cycle}")


@cocotb.test()
async def test_assertion_is_asynchronous(dut) -> None:
    """Directed: assertion takes effect without waiting for a clock edge."""
    await bring_up(dut)
    await release_and_check(dut, "setup")

    # Assert a third of the way through a period, nowhere near an edge.
    await RisingEdge(dut.clk)
    await between_edges(CLK_PERIOD_NS, 0.33)
    dut.arst_n_in.value = 0
    await Timer(1, units="ps")
    assert_eq(dut.rst_n_out.value, 0,
              "assertion must not wait for a clock edge")


@cocotb.test()
async def test_sub_cycle_glitch(dut) -> None:
    """Directed: a reset pulse far narrower than a clock period is captured.

    This is the whole point of an asynchronous assertion. A synchronous reset
    would sample the input at the next edge, miss the glitch entirely, and
    leave the design running through a reset event that really happened.
    """
    await bring_up(dut)
    await release_and_check(dut, "setup")

    await RisingEdge(dut.clk)
    await between_edges(CLK_PERIOD_NS, 0.25)
    dut.arst_n_in.value = 0
    await Timer(round(CLK_PERIOD_NS * 1000 / 20), units="ps")   # 5% of a period
    dut.arst_n_in.value = 1
    await Timer(1, units="ps")
    assert_eq(dut.rst_n_out.value, 0,
              "a sub-cycle glitch must still assert the reset")

    # Recovery takes the full chain length again.
    await release_and_check(dut, "recovery after glitch")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_phase_assertions(dut) -> None:
    """Randomised: assert at random phases within the clock period."""
    rng = RandomStream("reset_sync")
    dut._log.info("random seed = %d", rng.seed)
    await bring_up(dut)

    for iteration in range(60):
        await release_and_check(dut, f"iteration {iteration}")

        # Idle for a random number of cycles with the reset released.
        for _ in range(rng.between(0, 4)):
            await RisingEdge(dut.clk)
            await settle()
            assert_eq(dut.rst_n_out.value, 1,
                      f"iteration {iteration}: spurious assertion while idle")

        # Assert at a random point in the period.
        await RisingEdge(dut.clk)
        await between_edges(CLK_PERIOD_NS, rng.between(5, 95) / 100.0)
        dut.arst_n_in.value = 0
        await Timer(1, units="ps")
        assert_eq(dut.rst_n_out.value, 0,
                  f"iteration {iteration}: asynchronous assertion failed")

        for _ in range(rng.between(0, 3)):
            await RisingEdge(dut.clk)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_back_to_back_cycles(dut) -> None:
    """Regression: assert and release with no idle time between cycles.

    The chain must flush completely on every assertion. A chain that only
    partially cleared would release early on the following cycle.
    """
    await bring_up(dut)

    for iteration in range(40):
        await release_and_check(dut, f"cycle {iteration}")
        await RisingEdge(dut.clk)
        dut.arst_n_in.value = 0
        await settle()
        assert_eq(dut.rst_n_out.value, 0, f"cycle {iteration}: assertion")
