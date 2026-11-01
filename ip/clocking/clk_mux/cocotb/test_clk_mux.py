"""Cocotb regression for clk_mux.

Coverage
    directed   reset selects clk0, switching in both directions, clk_active
               reporting the live clock, the output rate following the
               selected source
    randomised switching at asynchronous times while respecting the usage rule
    regression the usage rule deliberately violated - select toggled part way
               through a changeover - which must still never glitch

Every test runs with a phase monitor attached. The output is allowed to be
*slow* during the dead time between one clock releasing and the other taking
over, but never *fast*: any phase shorter than the narrowest source phase is a
runt and would violate the minimum pulse width of every downstream flip-flop.
"""
from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Edge, RisingEdge, Timer
from cocotb.utils import get_sim_time

from socip import RandomStream, assert_eq, describe, get_param, start_clock

STAGES = get_param("STAGES", 2)

# Unrelated periods: nothing may depend on a rational ratio.
CLK0_PERIOD_NS = 10.0
CLK1_PERIOD_NS = 27.0

# Narrowest legal phase on the output, in picoseconds.
MIN_PHASE_PS = round(min(CLK0_PERIOD_NS, CLK1_PERIOD_NS) * 1000 / 2)
TOLERANCE_PS = 2

# Bound on how long a changeover may take: STAGES cycles of each clock, with
# generous margin for the dead time in between.
SWITCH_TIMEOUT_NS = (STAGES + 4) * (CLK0_PERIOD_NS + CLK1_PERIOD_NS)


class PhaseMonitor:
    """Fails on any output phase shorter than the narrowest source phase."""

    def __init__(self, dut) -> None:
        self.dut = dut
        self.phases = 0
        self.errors: list[str] = []
        self._task = None

    def start(self) -> "PhaseMonitor":
        self._task = cocotb.start_soon(self._run())
        return self

    def stop(self) -> None:
        if self._task is not None:
            self._task.kill()
            self._task = None

    async def _run(self) -> None:
        await Edge(self.dut.clk_out)
        previous = get_sim_time("ps")
        while True:
            await Edge(self.dut.clk_out)
            now = get_sim_time("ps")
            phase = now - previous
            previous = now
            self.phases += 1
            if phase < MIN_PHASE_PS - TOLERANCE_PS:
                self.errors.append(
                    f"runt phase of {phase} ps at {now} ps "
                    f"(minimum legal {MIN_PHASE_PS} ps)")

    def check(self, context: str) -> None:
        if self.errors:
            raise AssertionError(f"{context}: {self.errors[0]} "
                                 f"({len(self.errors)} problem(s) total)")


async def bring_up(dut) -> PhaseMonitor:
    """Start both clocks and release both resets."""
    dut._log.info("clk_mux: STAGES=%d, clk0=%.1f ns, clk1=%.1f ns, %s",
                  STAGES, CLK0_PERIOD_NS, CLK1_PERIOD_NS, describe())

    dut.select.value = 0
    dut.rst0_n.value = 0
    dut.rst1_n.value = 0

    start_clock(dut.clk0, CLK0_PERIOD_NS)
    start_clock(dut.clk1, CLK1_PERIOD_NS)

    for _ in range(4):
        await RisingEdge(dut.clk0)
    for _ in range(4):
        await RisingEdge(dut.clk1)

    dut.rst0_n.value = 1
    dut.rst1_n.value = 1
    await RisingEdge(dut.clk0)

    return PhaseMonitor(dut).start()


async def request_clock(dut, which: int) -> None:
    """Request a clock and wait for the changeover to complete.

    The block requires select to be stable until clk_active has followed it;
    this helper is what respecting that rule looks like in practice.
    """
    dut.select.value = which
    deadline = get_sim_time("ps") + round(SWITCH_TIMEOUT_NS * 1000)
    while int(dut.clk_active.value) != which:
        await Timer(1, units="ns")
        if get_sim_time("ps") > deadline:
            raise AssertionError(f"switch to clk{which} never completed")


async def count_output_edges(dut, duration_ns: float) -> int:
    """Count clk_out rising edges over a fixed span of simulation time."""
    edges = 0
    deadline = get_sim_time("ps") + round(duration_ns * 1000)

    async def counter() -> None:
        nonlocal edges
        while True:
            await RisingEdge(dut.clk_out)
            edges += 1

    task = cocotb.start_soon(counter())
    while get_sim_time("ps") < deadline:
        await Timer(1, units="ns")
    task.kill()
    return edges


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_selects_clk0(dut) -> None:
    """Directed: the output follows clk0 out of reset."""
    monitor = await bring_up(dut)

    assert_eq(dut.clk_active.value, 0, "clk_active after reset")

    span = 20 * CLK0_PERIOD_NS
    edges = await count_output_edges(dut, span)
    expected = span / CLK0_PERIOD_NS

    assert abs(edges - expected) <= 2, (
        f"expected about {expected:.0f} edges at the clk0 rate, got {edges}")
    monitor.check("reset state")


@cocotb.test()
async def test_switch_to_clk1_and_back(dut) -> None:
    """Directed: switching in both directions, with clk_active reporting it."""
    monitor = await bring_up(dut)

    await request_clock(dut, 1)
    assert_eq(dut.clk_active.value, 1, "clk_active after switching to clk1")

    span = 20 * CLK1_PERIOD_NS
    edges = await count_output_edges(dut, span)
    expected = span / CLK1_PERIOD_NS
    assert abs(edges - expected) <= 2, (
        f"expected about {expected:.0f} edges at the clk1 rate, got {edges}")

    await request_clock(dut, 0)
    assert_eq(dut.clk_active.value, 0, "clk_active after switching back")

    span = 20 * CLK0_PERIOD_NS
    edges = await count_output_edges(dut, span)
    expected = span / CLK0_PERIOD_NS
    assert abs(edges - expected) <= 2, (
        f"expected about {expected:.0f} edges at the clk0 rate, got {edges}")

    monitor.check("switch both ways")


@cocotb.test()
async def test_repeated_switching(dut) -> None:
    """Directed: many switches back to back, each allowed to complete."""
    monitor = await bring_up(dut)

    for index in range(20):
        await request_clock(dut, index % 2)
        # Dwell on the new clock before asking for the next one. Without a
        # dwell the output spends nearly all its time in the changeover dead
        # zone, which exercises the switching logic but barely produces any
        # output edges to measure.
        await Timer(60, units="ns")

    assert_eq(dut.clk_active.value, 1, "clk_active after the final switch")
    monitor.check("repeated switching")
    # request_clock() already fails if a changeover never completes, so this
    # only guards against the monitor silently observing nothing at all.
    assert monitor.phases > 100, (
        f"only {monitor.phases} output phases observed; the monitor is not "
        "seeing the output")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_switching(dut) -> None:
    """Randomised: switches requested at asynchronous times, rule respected."""
    rng = RandomStream("clk_mux")
    dut._log.info("random seed = %d", rng.seed)
    monitor = await bring_up(dut)

    for _ in range(40):
        await Timer(rng.between(5, 120), units="ns")
        await request_clock(dut, rng.between(0, 1))

    await request_clock(dut, 0)
    monitor.check("randomised switching")
    dut._log.info("%d output phases measured, none runt", monitor.phases)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_rule_violation_never_glitches(dut) -> None:
    """Regression: select toggled mid-changeover must still not glitch.

    Withdrawing a request part way through a changeover is outside the
    documented usage, and the only guarantee is that the switch is delayed —
    but a glitch-free mux that glitches under abuse is not glitch-free. The
    chains clear rather than shift precisely so that a stale request cannot
    complete behind a withdrawal.
    """
    rng = RandomStream("clk_mux_abuse")
    dut._log.info("random seed = %d", rng.seed)
    monitor = await bring_up(dut)

    for _ in range(200):
        await Timer(rng.between(3, 40), units="ns")
        dut.select.value = rng.between(0, 1)

    await request_clock(dut, 0)
    monitor.check("usage rule violated")
    dut._log.info("%d phases measured under abuse, none runt", monitor.phases)


@cocotb.test()
async def test_stalled_clock_parks_safely(dut) -> None:
    """Regression: requesting a stopped clock parks the output, never glitches.

    Both clocks must be running for a changeover to complete. If the incoming
    clock is dead the block never finishes the switch and holds the output
    low. That is the safe failure, and far better than a glitch: downstream
    logic simply stops rather than being clocked by a malformed edge.
    """
    dut._log.info("clk_mux: stalled-source behaviour")
    dut.select.value = 0
    dut.rst0_n.value = 0
    dut.rst1_n.value = 0

    start_clock(dut.clk0, CLK0_PERIOD_NS)
    # Started by hand so the driver can be stopped later, which start_clock's
    # fire-and-forget interface deliberately does not allow.
    clk1_driver = cocotb.start_soon(
        Clock(dut.clk1, CLK1_PERIOD_NS, units="ns").start())

    for _ in range(4):
        await RisingEdge(dut.clk0)
    for _ in range(4):
        await RisingEdge(dut.clk1)
    dut.rst0_n.value = 1
    dut.rst1_n.value = 1
    await RisingEdge(dut.clk0)

    monitor = PhaseMonitor(dut).start()

    # Confirm normal operation first, so a failure below is attributable to
    # the stalled clock rather than to the setup.
    await request_clock(dut, 1)
    await request_clock(dut, 0)

    # Kill clk1 and park it low, then ask for it.
    clk1_driver.kill()
    dut.clk1.value = 0
    await RisingEdge(dut.clk0)
    dut.select.value = 1

    await Timer(round(SWITCH_TIMEOUT_NS), units="ns")

    assert_eq(dut.clk_active.value, 0,
              "clk_active must not report a clock that is not running")
    assert_eq(dut.clk_out.value, 0,
              "the output must park low rather than glitch")
    monitor.check("stalled source")

    # Restarting the source completes the pending switch on its own.
    cocotb.start_soon(Clock(dut.clk1, CLK1_PERIOD_NS, units="ns").start())
    await request_clock(dut, 1)
    monitor.check("source restarted")
