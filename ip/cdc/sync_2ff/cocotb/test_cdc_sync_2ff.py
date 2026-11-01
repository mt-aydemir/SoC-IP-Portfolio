"""cocotb testbench for cdc_sync_2ff.

Coverage
    directed   reset behaviour, exact pipeline latency, static hold
    random     long randomised stream compared against a shift-register model
    regression back-to-back toggling on every bit, and reset asserted mid-flow
"""
from __future__ import annotations

from collections import deque

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from socip import (
    ClockDomain,
    RandomStream,
    assert_eq,
    between_edges,
    describe,
    get_param,
    settle,
)

CLK_PERIOD_NS = 4.0


def cfg() -> tuple[int, int, int]:
    """(WIDTH, STAGES, RESET_VALUE) the DUT was elaborated with."""
    return (get_param("WIDTH", 1), get_param("STAGES", 2), get_param("RESET_VALUE", 0))


async def bring_up(dut) -> ClockDomain:
    width, _, _ = cfg()
    dut._log.info(describe())
    dut.d_async.value = 0
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "dst").start()
    await domain.reset(cycles=3)
    assert width >= 1
    return domain


class ChainModel:
    """Reference model: a STAGES-deep shift register."""

    def __init__(self, stages: int, reset_value: int) -> None:
        self.pipe = deque([reset_value] * stages, maxlen=stages)

    def step(self, d: int) -> int:
        """Advance one clock edge with input *d*, return the new output."""
        self.pipe.appendleft(d)
        return self.pipe[-1]

    @property
    def out(self) -> int:
        return self.pipe[-1]


@cocotb.test()
async def test_reset_value(dut):
    """While reset is low every stage holds RESET_VALUE."""
    width, _, reset_value = cfg()
    mask = (1 << width) - 1

    dut.d_async.value = mask          # drive the opposite of the reset value
    dut.rst_n.value = 0
    ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS).start()

    for _ in range(6):
        await RisingEdge(dut.clk)
        await settle()
        assert_eq(dut.q_sync.value, reset_value & mask,
                  "q_sync must hold RESET_VALUE while rst_n is low")


@cocotb.test()
async def test_latency_is_exactly_stages(dut):
    """A change on d_async appears on q_sync after exactly STAGES edges."""
    width, stages, _ = cfg()
    mask = (1 << width) - 1
    domain = await bring_up(dut)

    await RisingEdge(dut.clk)
    dut.d_async.value = mask
    for cycle in range(1, stages + 1):
        await RisingEdge(dut.clk)
        await settle()
        expected = mask if cycle >= stages else 0
        assert_eq(dut.q_sync.value, expected,
                  f"cycle {cycle} of {stages}: propagation is off by a stage")

    # And it stays there.
    for _ in range(4):
        await RisingEdge(dut.clk)
        await settle()
        assert_eq(dut.q_sync.value, mask, "output must hold a stable input")

    await domain.cycles(1)


@cocotb.test()
async def test_random_stream(dut):
    """Long randomised input compared cycle-by-cycle against the model."""
    width, stages, reset_value = cfg()
    mask = (1 << width) - 1
    rng = RandomStream("sync_2ff", seed=None)
    dut._log.info("random seed = %d", rng.seed)

    await bring_up(dut)
    model = ChainModel(stages, reset_value & mask)

    for i in range(600):
        # Mix of fully random words and single-bit toggles.
        if rng.boolean(0.3):
            value = 1 << rng.between(0, width - 1)
        else:
            value = rng.corner_uint(width)
        value &= mask

        dut.d_async.value = value
        await RisingEdge(dut.clk)
        expected = model.step(value)
        await settle()
        assert_eq(dut.q_sync.value, expected, f"transaction {i}")


@cocotb.test()
async def test_toggle_every_cycle(dut):
    """Worst case activity: the input inverts on every single clock edge."""
    width, stages, reset_value = cfg()
    mask = (1 << width) - 1
    await bring_up(dut)

    model = ChainModel(stages, reset_value & mask)
    value = 0
    for i in range(200):
        value ^= mask
        dut.d_async.value = value
        await RisingEdge(dut.clk)
        expected = model.step(value)
        await settle()
        assert_eq(dut.q_sync.value, expected, f"toggle {i}")


@cocotb.test()
async def test_lanes_are_independent(dut):
    """Each bit has its own chain: driving one lane must not disturb another.

    This is the property that makes the block safe for a bundle of unrelated
    flags and unsafe for a multi-bit value. A shared enable or a shared reset
    term between lanes would show up here.
    """
    width, stages, reset_value = cfg()
    if width < 2:
        dut._log.info("WIDTH=%d: single lane, independence is trivial", width)
        return

    mask = (1 << width) - 1
    await bring_up(dut)
    model = ChainModel(stages, reset_value & mask)

    # Walk a single one through the bus, then a single zero through all-ones.
    for lane in range(width):
        value = 1 << lane
        dut.d_async.value = value
        await RisingEdge(dut.clk)
        expected = model.step(value)
        await settle()
        assert_eq(dut.q_sync.value, expected, f"walking one, lane {lane}")

    for lane in range(width):
        value = mask & ~(1 << lane)
        dut.d_async.value = value
        await RisingEdge(dut.clk)
        expected = model.step(value)
        await settle()
        assert_eq(dut.q_sync.value, expected, f"walking zero, lane {lane}")


@cocotb.test()
async def test_reset_during_traffic(dut):
    """Asynchronous reset flushes the chain and the chain refills correctly."""
    width, stages, reset_value = cfg()
    mask = (1 << width) - 1
    domain = await bring_up(dut)

    dut.d_async.value = mask
    await ClockCycles(dut.clk, stages + 2)
    await settle()
    assert_eq(dut.q_sync.value, mask, "chain should be full before reset")

    # Assert reset away from a clock edge to exercise the asynchronous path.
    await RisingEdge(dut.clk)
    await between_edges(CLK_PERIOD_NS, 0.33)
    dut.rst_n.value = 0
    await settle()
    assert_eq(dut.q_sync.value, reset_value & mask,
              "asynchronous reset must clear the output immediately")

    await ClockCycles(dut.clk, 2)
    await settle()
    dut.rst_n.value = 1

    model = ChainModel(stages, reset_value & mask)
    for i in range(stages + 4):
        await RisingEdge(dut.clk)
        expected = model.step(mask)
        await settle()
        assert_eq(dut.q_sync.value, expected, f"refill cycle {i}")

    await domain.cycles(1)
