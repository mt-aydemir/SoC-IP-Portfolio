"""Cocotb regression for accumulator.

Coverage
    directed   the reset state, a plain accumulation, the control priority
               (clear beats load beats enable), the hold behaviour when
               nothing is asserted, and the saturation limits in both
               directions
    randomised cycle-by-cycle random control and data against a
               cycle-accurate reference model
    regression a long accumulation that would overflow a too-narrow
               accumulator, the non-sticky nature of saturation, and a
               mid-stream reset

The reference model is a cycle-accurate Python replica of the specification:
it is stepped once per clock edge with the control inputs that were applied
before that edge, and its state is compared against ``acc_out`` and
``overflow`` after it. Anything the design does a cycle early or a cycle late
therefore fails, which is the class of defect an accumulator is most prone to.
"""
from __future__ import annotations

from dataclasses import dataclass

import cocotb
from cocotb.triggers import NextTimeStep, ReadOnly, RisingEdge

from socip import (
    ClockDomain,
    RandomStream,
    assert_eq,
    describe,
    get_param,
    to_signed,
)

DATA_WIDTH = get_param("DATA_WIDTH", 16)
ACC_WIDTH = get_param("ACC_WIDTH", 32)
SIGNED = get_param("SIGNED", 1)
SATURATE = get_param("SATURATE", 0)

CLK_PERIOD_NS = 5.0

DATA_MASK = (1 << DATA_WIDTH) - 1
ACC_MASK = (1 << ACC_WIDTH) - 1
ACC_SIGN = 1 << (ACC_WIDTH - 1)
MAX_SIGNED = ACC_SIGN - 1
MIN_SIGNED = ACC_SIGN
MAX_UNSIGNED = ACC_MASK


def widen(data: int) -> int:
    """Extend an addend to the accumulator width, as the RTL does.

    Sign extension for the signed case, zero extension otherwise. Getting this
    wrong is silent: an unsigned extension of a negative value adds a huge
    positive number instead of a small negative one, and the accumulator only
    looks wrong once the inputs go negative.
    """
    data &= DATA_MASK
    if SIGNED:
        return to_signed(data, DATA_WIDTH) & ACC_MASK
    return data


@dataclass
class Model:
    """Cycle-accurate reference for the accumulator."""

    acc: int = 0
    overflow: int = 0

    def reset(self) -> None:
        self.acc = 0
        self.overflow = 0

    def step(self, clear: int, load: int, enable: int,
             data_in: int, load_data: int) -> None:
        """Advance one clock edge with the control inputs applied before it."""
        if clear:
            self.acc = 0
            self.overflow = 0
            return
        if load:
            self.acc = load_data & ACC_MASK
            self.overflow = 0
            return
        if not enable:
            # The total holds; the flag does not. It describes the addition
            # performed on this edge, and no addition was performed.
            self.overflow = 0
            return

        addend = widen(data_in)
        wide = self.acc + addend
        total = wide & ACC_MASK
        carry = (wide >> ACC_WIDTH) & 1

        if SIGNED:
            sign_acc = (self.acc >> (ACC_WIDTH - 1)) & 1
            sign_addend = (addend >> (ACC_WIDTH - 1)) & 1
            sign_total = (total >> (ACC_WIDTH - 1)) & 1
            overflowed = int(sign_acc == sign_addend and sign_total != sign_acc)
        else:
            overflowed = carry

        if not SATURATE or not overflowed:
            self.acc = total
        elif SIGNED:
            self.acc = MIN_SIGNED if ((self.acc >> (ACC_WIDTH - 1)) & 1) \
                else MAX_SIGNED
        else:
            self.acc = MAX_UNSIGNED

        self.overflow = overflowed


class Driver:
    """Applies control inputs and checks the model after every edge."""

    def __init__(self, dut, domain: ClockDomain) -> None:
        self.dut = dut
        self.domain = domain
        self.model = Model()
        self.cycle = 0

    def idle(self) -> None:
        self.dut.clear.value = 0
        self.dut.load.value = 0
        self.dut.enable.value = 0
        self.dut.data_in.value = 0
        self.dut.load_data.value = 0

    async def reset(self) -> None:
        self.idle()
        await self.domain.reset()
        self.model.reset()
        await self.check("after reset")

    async def step(self, clear: int = 0, load: int = 0, enable: int = 0,
                   data_in: int = 0, load_data: int = 0,
                   context: str = "") -> None:
        """Drive one cycle, advance the model, and compare."""
        self.dut.clear.value = clear
        self.dut.load.value = load
        self.dut.enable.value = enable
        self.dut.data_in.value = data_in & DATA_MASK
        self.dut.load_data.value = load_data & ACC_MASK

        await RisingEdge(self.dut.clk)
        self.model.step(clear, load, enable, data_in, load_data)
        self.cycle += 1

        label = context or (f"cycle {self.cycle} "
                            f"(clear={clear} load={load} enable={enable} "
                            f"data=0x{data_in & DATA_MASK:X})")
        await self.check(label)

    async def check(self, context: str) -> None:
        """Compare the settled outputs, then return to a writable phase.

        The comparison has to happen in ``ReadOnly``, which is the one point
        in a time step where every value has settled; but no handle can be
        driven from there, so the check leaves the phase again before
        returning. Without that, the next call's writes would be illegal.
        """
        await ReadOnly()
        acc = int(self.dut.acc_out.value)
        overflow = int(self.dut.overflow.value)
        await NextTimeStep()

        assert_eq(acc, self.model.acc, f"acc_out {context}")
        assert_eq(overflow, self.model.overflow, f"overflow {context}")


async def setup(dut) -> tuple[ClockDomain, Driver]:
    """Bring the DUT up in a known state and return its driver."""
    dut._log.info("accumulator: DATA_WIDTH=%d ACC_WIDTH=%d SIGNED=%d "
                  "SATURATE=%d, %s",
                  DATA_WIDTH, ACC_WIDTH, SIGNED, SATURATE, describe())

    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    driver = Driver(dut, domain)
    await driver.reset()
    return domain, driver


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: the total and the flag are zero out of reset."""
    _domain, driver = await setup(dut)
    assert_eq(driver.model.acc, 0, "model agrees the reset total is zero")


@cocotb.test()
async def test_accumulate(dut) -> None:
    """Directed: a straightforward running total."""
    _domain, driver = await setup(dut)

    for value in (1, 2, 3, 4, 5):
        await driver.step(enable=1, data_in=value)


@cocotb.test()
async def test_hold(dut) -> None:
    """Directed: with nothing asserted the total holds and the flag clears.

    Saturation is sticky in effect but not in state, and this is where that
    distinction is visible: ``overflow`` describes the addition performed on
    this edge, so a cycle with no addition clears it even though the total is
    unchanged.
    """
    _domain, driver = await setup(dut)

    await driver.step(enable=1, data_in=7)
    for _ in range(5):
        await driver.step()        # idle: total holds, flag low


@cocotb.test()
async def test_load(dut) -> None:
    """Directed: load replaces the total and clears the flag."""
    _domain, driver = await setup(dut)

    await driver.step(enable=1, data_in=9)
    await driver.step(load=1, load_data=0x1234 & ACC_MASK)
    await driver.step(enable=1, data_in=1)


@cocotb.test()
async def test_clear(dut) -> None:
    """Directed: clear zeroes the total."""
    _domain, driver = await setup(dut)

    await driver.step(enable=1, data_in=0x55)
    await driver.step(clear=1)
    await driver.step(enable=1, data_in=1)


@cocotb.test()
async def test_control_priority(dut) -> None:
    """Directed: clear beats load beats accumulate.

    Clear is the recovery path and must always work, which is why nothing can
    mask it. The combinations below assert two or three controls at once, and
    each must resolve to the highest-priority one.
    """
    _domain, driver = await setup(dut)

    await driver.step(enable=1, data_in=0x20)

    await driver.step(clear=1, load=1, load_data=0xFFFF & ACC_MASK,
                      context="clear beats load")
    await driver.step(enable=1, data_in=0x11)

    await driver.step(clear=1, enable=1, data_in=0x33,
                      context="clear beats enable")
    await driver.step(enable=1, data_in=0x11)

    await driver.step(load=1, load_data=0x77, enable=1, data_in=0x44,
                      context="load beats enable")

    await driver.step(clear=1, load=1, load_data=0xAA, enable=1, data_in=0x55,
                      context="clear beats everything")


@cocotb.test()
async def test_saturation_limits(dut) -> None:
    """Directed: the total clamps at both limits instead of wrapping.

    With SATURATE off the same stimulus verifies the opposite property,
    because the model follows the parameter too.
    """
    _domain, driver = await setup(dut)

    if not SATURATE:
        dut._log.info("SATURATE=0: the same cases verify wrap-around instead")

    largest_positive = DATA_MASK >> 1
    most_negative = (1 << (DATA_WIDTH - 1)) & DATA_MASK

    # Walk up to the top limit and keep pushing.
    await driver.step(load=1, load_data=MAX_SIGNED if SIGNED else MAX_UNSIGNED)
    for _ in range(4):
        await driver.step(enable=1, data_in=largest_positive)

    # And down to the bottom one.
    await driver.step(load=1, load_data=MIN_SIGNED if SIGNED else 0)
    for _ in range(4):
        await driver.step(enable=1,
                          data_in=most_negative if SIGNED else DATA_MASK)


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_control(dut) -> None:
    """Randomised: random control and data, every cycle, against the model.

    The controls are drawn independently so that illegal-looking combinations
    occur: they are all legal, and the priority rule is what makes them
    well defined.
    """
    rng = RandomStream("accumulator")
    dut._log.info("random seed = %d", rng.seed)
    _domain, driver = await setup(dut)

    for _ in range(2000):
        await driver.step(
            clear=int(rng.boolean(0.05)),
            load=int(rng.boolean(0.08)),
            enable=int(rng.boolean(0.70)),
            data_in=rng.corner_uint(DATA_WIDTH),
            load_data=rng.corner_uint(ACC_WIDTH))


@cocotb.test()
async def test_random_near_the_limits(dut) -> None:
    """Randomised: totals loaded close to a limit, then pushed over it.

    Uniform random accumulation almost never reaches a limit in an
    accumulator wide enough to be useful, so the saturation and overflow logic
    has to be reached deliberately: the total is loaded within one addend of
    the boundary and then driven across it.
    """
    rng = RandomStream("accumulator_limits")
    dut._log.info("random seed = %d", rng.seed)
    _domain, driver = await setup(dut)

    for _ in range(400):
        if SIGNED:
            near = rng.choice([MAX_SIGNED, MAX_SIGNED - 1, MIN_SIGNED,
                               MIN_SIGNED + 1])
        else:
            near = rng.choice([MAX_UNSIGNED, MAX_UNSIGNED - 1, 0, 1])

        await driver.step(load=1, load_data=near)
        for _ in range(3):
            await driver.step(enable=1, data_in=rng.corner_uint(DATA_WIDTH))


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_growth_beyond_data_width(dut) -> None:
    """Regression: a long accumulation that a too-narrow total would wrap.

    Accumulating N values of DATA_WIDTH bits needs DATA_WIDTH + clog2(N) bits
    to hold every possible result, and getting that width wrong is the most
    common defect in accumulate loops: the sum is right for the test vectors
    and wraps on real data. Here the accumulator is deliberately driven past
    the point where the data width alone would have overflowed.
    """
    _domain, driver = await setup(dut)

    count = min(512, 1 << (ACC_WIDTH - DATA_WIDTH + 1))
    for _ in range(count):
        await driver.step(enable=1, data_in=DATA_MASK >> 1)


@cocotb.test()
async def test_saturation_is_not_sticky(dut) -> None:
    """Regression: a clamped total moves again when the input reverses.

    Saturation is sticky in effect but not in state: once clamped the total
    stays at the limit only while inputs keep pushing it there, and an input
    of the opposite sign moves it back. A latching saturation flag belongs to
    the consumer, which is what ``overflow`` is for.
    """
    _domain, driver = await setup(dut)

    if not SIGNED:
        dut._log.info("unsigned: reversing means subtracting, which this "
                      "block does not do; the equivalent check is that a "
                      "clamped total still responds to load")
        await driver.step(load=1, load_data=MAX_UNSIGNED)
        await driver.step(enable=1, data_in=DATA_MASK)
        await driver.step(load=1, load_data=0)
        await driver.step(enable=1, data_in=1)
        return

    await driver.step(load=1, load_data=MAX_SIGNED)
    await driver.step(enable=1, data_in=DATA_MASK >> 1)      # push over the top
    await driver.step(enable=1, data_in=(1 << (DATA_WIDTH - 1)) & DATA_MASK)
    for _ in range(4):
        await driver.step(enable=1,
                          data_in=(1 << (DATA_WIDTH - 1)) & DATA_MASK)


@cocotb.test()
async def test_reset_during_traffic(dut) -> None:
    """Regression: a mid-stream reset returns the block to the idle state."""
    rng = RandomStream("accumulator_reset")
    _domain, driver = await setup(dut)

    for _ in range(16):
        await driver.step(enable=1, data_in=rng.uint(DATA_WIDTH))

    await driver.reset()

    for _ in range(4):
        await driver.step(enable=1, data_in=rng.uint(DATA_WIDTH))
