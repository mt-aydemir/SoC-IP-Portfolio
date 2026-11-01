"""Cocotb regression for reset_controller.

Coverage
    directed   every stage asserted while the source is held, staged release
               in ascending order with exact STAGE_DELAY spacing, a one-cycle
               software request stretched to MIN_ASSERT_CYCLES, asynchronous
               assertion away from a clock edge, reset_active semantics
    randomised software resets of random width at random times
    regression back-to-back resets, checking the sequence is identical every
               time and that no stage ever releases early

An order monitor runs for the whole regression, so a stage released out of
turn fails whichever test happened to be running.
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
    sampled,
    settle,
    start_clock,
)

NUM_STAGES = get_param("NUM_STAGES", 4)
STAGE_DELAY = get_param("STAGE_DELAY", 4)
MIN_ASSERT_CYCLES = get_param("MIN_ASSERT_CYCLES", 16)
SYNC_STAGES = get_param("SYNC_STAGES", 3)

CLK_PERIOD_NS = 10.0
ALL_RELEASED = (1 << NUM_STAGES) - 1

# Worst case for a full release, with margin: synchroniser depth, the minimum
# assertion time, and every stage delay.
RELEASE_TIMEOUT = SYNC_STAGES + MIN_ASSERT_CYCLES + NUM_STAGES * STAGE_DELAY + 32


class OrderMonitor:
    """Fails if a stage is ever released while a lower stage is still asserted."""

    def __init__(self, dut) -> None:
        self.dut = dut
        self.errors: list[str] = []
        self._task = None

    def start(self) -> "OrderMonitor":
        self._task = cocotb.start_soon(self._run())
        return self

    async def _run(self) -> None:
        while True:
            await RisingEdge(self.dut.clk)
            await settle()
            value = int(self.dut.rst_n_out.value)
            for stage in range(1, NUM_STAGES):
                if (value >> stage) & 1 and not (value >> (stage - 1)) & 1:
                    self.errors.append(
                        f"stage {stage} released while stage {stage - 1} "
                        f"was still asserted (0x{value:X})")

    def check(self, context: str) -> None:
        if self.errors:
            raise AssertionError(f"{context}: {self.errors[0]} "
                                 f"({len(self.errors)} problem(s) total)")


async def bring_up(dut) -> OrderMonitor:
    """Start the clock with the asynchronous reset held."""
    dut._log.info("reset_controller: NUM_STAGES=%d, STAGE_DELAY=%d, "
                  "MIN_ASSERT_CYCLES=%d, %s",
                  NUM_STAGES, STAGE_DELAY, MIN_ASSERT_CYCLES, describe())
    dut.arst_n_in.value = 0
    dut.sw_reset.value = 0
    start_clock(dut.clk, CLK_PERIOD_NS)
    for _ in range(4):
        await RisingEdge(dut.clk)
    return OrderMonitor(dut).start()


async def capture_release_sequence(dut) -> list[int]:
    """Return the clock cycle on which each stage released, relative to the first.

    Cycles are counted from the moment the function starts observing, so only
    the *differences* between entries are meaningful — which is exactly what
    the block promises.
    """
    released = [None] * NUM_STAGES
    for cycle in range(RELEASE_TIMEOUT):
        await RisingEdge(dut.clk)
        value = await sampled(dut.rst_n_out)
        for stage in range(NUM_STAGES):
            if released[stage] is None and (value >> stage) & 1:
                released[stage] = cycle
        if all(entry is not None for entry in released):
            return released

    raise AssertionError(
        f"not every stage released within {RELEASE_TIMEOUT} cycles "
        f"(released={released})")


def check_spacing(released: list[int], context: str) -> None:
    for stage in range(1, NUM_STAGES):
        spacing = released[stage] - released[stage - 1]
        assert spacing == STAGE_DELAY, (
            f"{context}: stages {stage - 1} and {stage} are {spacing} cycles "
            f"apart, expected {STAGE_DELAY}")


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_all_stages_asserted_while_held(dut) -> None:
    """Directed: every stage stays asserted while the source is low."""
    monitor = await bring_up(dut)

    for cycle in range(12):
        await RisingEdge(dut.clk)
        value = await sampled(dut.rst_n_out)
        assert_eq(value, 0, f"rst_n_out at cycle {cycle}")

    assert_eq(await sampled(dut.reset_active), 1, "reset_active while held")
    monitor.check("held in reset")


@cocotb.test()
async def test_staged_release(dut) -> None:
    """Directed: stages release in order, exactly STAGE_DELAY cycles apart."""
    monitor = await bring_up(dut)

    await RisingEdge(dut.clk)
    await between_edges(CLK_PERIOD_NS, 0.5)
    dut.arst_n_in.value = 1

    released = await capture_release_sequence(dut)
    check_spacing(released, "power-on release")
    dut._log.info("release cycles: %s", released)

    for _ in range(4):
        await RisingEdge(dut.clk)
    assert_eq(await sampled(dut.reset_active), 0,
              "reset_active must fall once every stage has released")
    monitor.check("power-on release")


@cocotb.test()
async def test_software_reset_stretched(dut) -> None:
    """Directed: a one-cycle request produces at least MIN_ASSERT_CYCLES."""
    monitor = await bring_up(dut)
    dut.arst_n_in.value = 1
    await capture_release_sequence(dut)

    # A single-cycle request, exactly as a CPU write strobe would present it.
    await RisingEdge(dut.clk)
    dut.sw_reset.value = 1
    await RisingEdge(dut.clk)
    dut.sw_reset.value = 0

    assert_eq(await sampled(dut.rst_n_out), 0,
              "a software reset must assert every stage")

    held = 0
    for _ in range(RELEASE_TIMEOUT):
        await RisingEdge(dut.clk)
        if (await sampled(dut.rst_n_out)) & 1:
            break
        held += 1
    else:
        raise AssertionError("stage 0 never released after the software reset")

    assert held >= MIN_ASSERT_CYCLES - 1, (
        f"a one-cycle request produced only {held} cycles of reset, "
        f"minimum is {MIN_ASSERT_CYCLES}")

    monitor.check("software reset")


@cocotb.test()
async def test_asynchronous_assertion(dut) -> None:
    """Directed: assertion takes effect without waiting for a clock edge."""
    monitor = await bring_up(dut)
    dut.arst_n_in.value = 1
    await capture_release_sequence(dut)

    await RisingEdge(dut.clk)
    await between_edges(CLK_PERIOD_NS, 0.33)
    dut.arst_n_in.value = 0
    await Timer(1, units="ps")

    assert_eq(dut.rst_n_out.value, 0,
              "asynchronous assertion must not wait for a clock edge")
    monitor.check("asynchronous assertion")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_software_resets(dut) -> None:
    """Randomised: requests of random width, at random times."""
    rng = RandomStream("reset_controller")
    dut._log.info("random seed = %d", rng.seed)
    monitor = await bring_up(dut)

    dut.arst_n_in.value = 1
    await capture_release_sequence(dut)

    for iteration in range(15):
        for _ in range(rng.between(0, 8)):
            await RisingEdge(dut.clk)

        await RisingEdge(dut.clk)
        dut.sw_reset.value = 1
        for _ in range(rng.between(1, 4)):
            await RisingEdge(dut.clk)
        dut.sw_reset.value = 0

        released = await capture_release_sequence(dut)
        check_spacing(released, f"iteration {iteration}")

    monitor.check("randomised software resets")


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_sequence_is_repeatable(dut) -> None:
    """Regression: every reset produces an identical release sequence.

    A counter that failed to clear, or a stage register that held its value
    across an assertion, would show up as a sequence that differs between
    iterations.
    """
    monitor = await bring_up(dut)
    dut.arst_n_in.value = 1

    reference = await capture_release_sequence(dut)
    check_spacing(reference, "first release")
    baseline = [cycle - reference[0] for cycle in reference]

    for iteration in range(12):
        await RisingEdge(dut.clk)
        dut.arst_n_in.value = 0
        for _ in range(4):
            await RisingEdge(dut.clk)
        dut.arst_n_in.value = 1

        released = await capture_release_sequence(dut)
        relative = [cycle - released[0] for cycle in released]
        assert relative == baseline, (
            f"iteration {iteration}: release sequence {relative} differs from "
            f"the first one {baseline}")

    monitor.check("repeatability")
