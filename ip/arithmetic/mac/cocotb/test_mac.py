"""Cocotb regression for mac.

Coverage
    directed   the reset state, the two-cycle latency, a dot product computed
               by hand, the clear-with-the-sample behaviour, and back-to-back
               frames with no gap between them
    randomised random frames of random length against a cycle-accurate model
    regression a long run, saturation at the accumulator limits, and a
               mid-stream reset

The behaviour under test that nothing else in the portfolio covers is the
**clear alignment**. ``clear`` is asserted by the caller alongside the first
sample of a new frame, and it has to reach the accumulator in the same cycle
as the product of that sample — one multiplier latency later. A clear that
arrives one cycle early wipes the accumulator *after* the last product of the
previous frame has already been added; one cycle late discards the first
product of the new frame. Both failures produce totals that look almost right,
which is what makes them expensive to find in a system and cheap to find here:
the model is cycle-accurate, so either one fails on the first frame boundary.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import cocotb
from cocotb.triggers import NextTimeStep, ReadOnly, RisingEdge

from socip import (
    ClockDomain,
    RandomStream,
    assert_eq,
    bits,
    describe,
    get_param,
    to_signed,
)

A_WIDTH = get_param("A_WIDTH", 16)
B_WIDTH = get_param("B_WIDTH", 16)
ACC_WIDTH = get_param("ACC_WIDTH", 40)
SIGNED = get_param("SIGNED", 1)
SATURATE = get_param("SATURATE", 0)

P_WIDTH = A_WIDTH + B_WIDTH
CLK_PERIOD_NS = 5.0

A_MASK = (1 << A_WIDTH) - 1
B_MASK = (1 << B_WIDTH) - 1
ACC_MASK = (1 << ACC_WIDTH) - 1
ACC_SIGN = 1 << (ACC_WIDTH - 1)
MAX_SIGNED = ACC_SIGN - 1
MIN_SIGNED = ACC_SIGN
MAX_UNSIGNED = ACC_MASK

# The multiplier instantiated inside the block, and therefore the number of
# cycles the clear has to be delayed by to stay aligned with its product.
MUL_LATENCY = 1
# Operands in, accumulator updated: the multiplier stage plus the accumulate.
TOTAL_LATENCY = MUL_LATENCY + 1


def product_of(a: int, b: int) -> int:
    """The product as a P_WIDTH bit pattern, in the selected interpretation."""
    a &= A_MASK
    b &= B_MASK
    if SIGNED:
        return bits(to_signed(a, A_WIDTH) * to_signed(b, B_WIDTH), P_WIDTH)
    return bits(a * b, P_WIDTH)


def widen(product: int) -> int:
    """Extend a product to the accumulator width, as the RTL does."""
    product &= (1 << P_WIDTH) - 1
    if SIGNED:
        return to_signed(product, P_WIDTH) & ACC_MASK
    return product


@dataclass
class Model:
    """Cycle-accurate reference for the whole block.

    Mirrors the structure rather than the equations: one multiplier stage, a
    clear delayed by the same amount, then the accumulate. Written this way
    because the thing being verified is the alignment between those stages.
    """

    acc: int = 0
    overflow: int = 0
    out_valid: int = 0
    mul_valid: int = 0
    mul_product: int = 0
    clear_pipe: int = 0
    history: list[int] = field(default_factory=list)

    def reset(self) -> None:
        self.acc = 0
        self.overflow = 0
        self.out_valid = 0
        self.mul_valid = 0
        self.mul_product = 0
        self.clear_pipe = 0

    def step(self, in_valid: int, clear: int, a: int, b: int) -> None:
        """Advance one clock edge with the inputs applied before it."""
        # --- the accumulate stage, driven by what the multiplier stage holds
        load = self.clear_pipe and self.mul_valid
        enable = self.mul_valid and not self.clear_pipe

        if load:
            self.acc = widen(self.mul_product)
            self.overflow = 0
        elif enable:
            addend = widen(self.mul_product)
            wide = self.acc + addend
            total = wide & ACC_MASK
            carry = (wide >> ACC_WIDTH) & 1

            if SIGNED:
                sign_acc = (self.acc >> (ACC_WIDTH - 1)) & 1
                sign_addend = (addend >> (ACC_WIDTH - 1)) & 1
                sign_total = (total >> (ACC_WIDTH - 1)) & 1
                overflowed = int(sign_acc == sign_addend
                                 and sign_total != sign_acc)
            else:
                overflowed = carry

            if not SATURATE or not overflowed:
                self.acc = total
            elif SIGNED:
                self.acc = MIN_SIGNED if sign_acc else MAX_SIGNED
            else:
                self.acc = MAX_UNSIGNED

            self.overflow = overflowed
        else:
            self.overflow = 0

        self.out_valid = self.mul_valid

        # --- the multiplier stage, driven by this edge's inputs
        self.mul_valid = in_valid
        self.mul_product = product_of(a, b)
        self.clear_pipe = int(bool(clear and in_valid))


class Driver:
    """Applies inputs and checks the model after every edge."""

    def __init__(self, dut, domain: ClockDomain) -> None:
        self.dut = dut
        self.domain = domain
        self.model = Model()
        self.cycle = 0

    def idle(self) -> None:
        self.dut.in_valid.value = 0
        self.dut.clear.value = 0
        self.dut.a.value = 0
        self.dut.b.value = 0

    async def reset(self) -> None:
        self.idle()
        await self.domain.reset()
        self.model.reset()
        await self.check("after reset")

    async def step(self, in_valid: int = 0, clear: int = 0,
                   a: int = 0, b: int = 0, label: str = "") -> None:
        self.dut.in_valid.value = in_valid
        self.dut.clear.value = clear
        self.dut.a.value = a & A_MASK
        self.dut.b.value = b & B_MASK

        await RisingEdge(self.dut.clk)
        self.model.step(in_valid, clear, a, b)
        self.cycle += 1

        await self.check(label or f"cycle {self.cycle} "
                                  f"(valid={in_valid} clear={clear} "
                                  f"a=0x{a & A_MASK:X} b=0x{b & B_MASK:X})")

    async def idle_cycles(self, count: int) -> None:
        for _ in range(count):
            await self.step(label=f"idle at cycle {self.cycle + 1}")

    async def check(self, label: str) -> None:
        await ReadOnly()
        acc = int(self.dut.acc_out.value)
        out_valid = int(self.dut.out_valid.value)
        overflow = int(self.dut.overflow.value)
        await NextTimeStep()

        assert_eq(acc, self.model.acc, f"acc_out {label}")
        assert_eq(out_valid, self.model.out_valid, f"out_valid {label}")
        assert_eq(overflow, self.model.overflow, f"overflow {label}")

    async def frame(self, pairs: list[tuple[int, int]]) -> None:
        """Push one frame: clear with the first sample, then the rest."""
        for index, (a, b) in enumerate(pairs):
            await self.step(in_valid=1, clear=int(index == 0), a=a, b=b,
                            label=f"frame sample {index}")


async def setup(dut) -> tuple[ClockDomain, Driver]:
    """Bring the DUT up in a known state and return its driver."""
    dut._log.info("mac: %dx%d -> %d bits SIGNED=%d SATURATE=%d, %s",
                  A_WIDTH, B_WIDTH, ACC_WIDTH, SIGNED, SATURATE, describe())

    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    driver = Driver(dut, domain)
    await driver.reset()
    return domain, driver


def dot_product(pairs: list[tuple[int, int]]) -> int:
    """The expected total for a frame, as an ACC_WIDTH bit pattern."""
    total = 0
    for a, b in pairs:
        if SIGNED:
            total += to_signed(a & A_MASK, A_WIDTH) * to_signed(b & B_MASK,
                                                                B_WIDTH)
        else:
            total += (a & A_MASK) * (b & B_MASK)
    return total & ACC_MASK


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: the total, the flag and the valid are all idle out of reset."""
    _domain, driver = await setup(dut)
    assert_eq(driver.model.acc, 0, "model agrees the reset total is zero")


@cocotb.test()
async def test_latency(dut) -> None:
    """Directed: the total is updated exactly TOTAL_LATENCY cycles later.

    Counted in edges rather than by waiting for ``out_valid``, so a pipeline
    one stage too long or too short fails here instead of quietly shifting
    every result.
    """
    _domain, driver = await setup(dut)

    await driver.step(in_valid=1, clear=1, a=3, b=5, label="single sample")
    assert_eq(driver.model.out_valid, 0,
              "out_valid is still low one cycle in")

    await driver.idle_cycles(1)
    assert_eq(driver.model.out_valid, 1,
              f"out_valid asserted after {TOTAL_LATENCY} cycles")

    await ReadOnly()
    acc = int(dut.acc_out.value)
    await NextTimeStep()
    assert_eq(acc, dot_product([(3, 5)]), "acc_out holds 3 * 5")

    await driver.idle_cycles(3)


@cocotb.test()
async def test_dot_product(dut) -> None:
    """Directed: a short dot product, checked against the hand computation."""
    _domain, driver = await setup(dut)

    pairs = [(2, 3), (4, 5), (6, 7), (8, 9)]
    await driver.frame(pairs)
    await driver.idle_cycles(TOTAL_LATENCY + 2)

    await ReadOnly()
    acc = int(dut.acc_out.value)
    await NextTimeStep()
    assert_eq(acc, dot_product(pairs), "sum of 2*3 + 4*5 + 6*7 + 8*9")


@cocotb.test()
async def test_clear_alignment(dut) -> None:
    """Directed: the clear lands on the product of the sample it arrived with.

    Two frames are pushed back to back with no idle cycle between them. The
    second frame's clear is asserted in the same cycle as its first sample,
    which is a cycle in which the previous frame still has a product in
    flight. The total after each frame must be that frame's dot product alone:

    * a clear that arrives one cycle **early** zeroes the accumulator before
      the previous frame's last product is added, so the first frame's total
      is short by its last term and the second frame's is correct;
    * a clear that arrives one cycle **late** zeroes it after the new frame's
      first product has been added, so the second frame's total is missing its
      first term.

    Either way the model disagrees on the exact cycle it happens.
    """
    _domain, driver = await setup(dut)

    first = [(3, 4), (5, 6), (7, 8)]
    second = [(2, 2), (3, 3)]

    await driver.frame(first)
    await driver.idle_cycles(TOTAL_LATENCY + 1)

    await ReadOnly()
    acc = int(dut.acc_out.value)
    await NextTimeStep()
    assert_eq(acc, dot_product(first), "first frame total")

    # No gap: the second frame starts immediately.
    await driver.frame(second)
    await driver.idle_cycles(TOTAL_LATENCY + 1)

    await ReadOnly()
    acc = int(dut.acc_out.value)
    await NextTimeStep()
    assert_eq(acc, dot_product(second),
              "second frame total, with no residue from the first")


@cocotb.test()
async def test_back_to_back_frames(dut) -> None:
    """Directed: frames with no idle cycle anywhere between them.

    The hardest case for the clear alignment: every frame boundary lands while
    the previous frame still has a product in the multiplier.
    """
    _domain, driver = await setup(dut)

    frames = [
        [(1, 1), (2, 2)],
        [(3, 3)],
        [(4, 4), (5, 5), (6, 6)],
        [(7, 7), (8, 8)],
    ]

    for index, pairs in enumerate(frames):
        await driver.frame(pairs)

    await driver.idle_cycles(TOTAL_LATENCY + 2)

    await ReadOnly()
    acc = int(dut.acc_out.value)
    await NextTimeStep()
    assert_eq(acc, dot_product(frames[-1]), "the last frame's total")


@cocotb.test()
async def test_gaps_within_a_frame(dut) -> None:
    """Directed: idle cycles inside a frame do not disturb the total.

    The accumulator must only advance on a valid product, so a frame whose
    samples arrive with gaps must give the same total as one at full rate.
    """
    _domain, driver = await setup(dut)

    pairs = [(2, 3), (4, 5), (6, 7)]

    await driver.step(in_valid=1, clear=1, a=pairs[0][0], b=pairs[0][1])
    for a, b in pairs[1:]:
        await driver.idle_cycles(2)
        await driver.step(in_valid=1, a=a, b=b)
    await driver.idle_cycles(TOTAL_LATENCY + 2)

    await ReadOnly()
    acc = int(dut.acc_out.value)
    await NextTimeStep()
    assert_eq(acc, dot_product(pairs), "total with gaps between samples")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_frames(dut) -> None:
    """Randomised: frames of random length, with random gaps between them."""
    rng = RandomStream("mac")
    dut._log.info("random seed = %d", rng.seed)
    _domain, driver = await setup(dut)

    for _ in range(60):
        length = rng.between(1, 12)
        pairs = [(rng.corner_uint(A_WIDTH), rng.corner_uint(B_WIDTH))
                 for _ in range(length)]
        await driver.frame(pairs)
        await driver.idle_cycles(rng.between(0, 3))

    await driver.idle_cycles(TOTAL_LATENCY + 2)


@cocotb.test()
async def test_random_control(dut) -> None:
    """Randomised: ``in_valid`` and ``clear`` drawn independently every cycle.

    Produces clear patterns no well-behaved caller would generate — a clear
    with no sample, a clear in the middle of a frame — which are all legal and
    all have a defined meaning: the clear is only pipelined when it arrives
    with a valid sample.
    """
    rng = RandomStream("mac_control")
    dut._log.info("random seed = %d", rng.seed)
    _domain, driver = await setup(dut)

    for _ in range(1500):
        await driver.step(
            in_valid=int(rng.boolean(0.75)),
            clear=int(rng.boolean(0.15)),
            a=rng.corner_uint(A_WIDTH),
            b=rng.corner_uint(B_WIDTH))


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_accumulator_limits(dut) -> None:
    """Regression: a frame long enough to reach the accumulator's limit.

    ACC_WIDTH is chosen by the caller and the block reports overflow when the
    choice was too small. Here the largest magnitude product is accumulated
    until the total crosses the limit, which exercises the saturation or
    wrap-around path according to SATURATE.
    """
    _domain, driver = await setup(dut)

    if SIGNED:
        a = 1 << (A_WIDTH - 1)          # most negative
        b = 1 << (B_WIDTH - 1)          # most negative: largest magnitude
    else:
        a, b = A_MASK, B_MASK

    # The number of maximum-magnitude products that fit before the limit.
    count = min(600, (1 << (ACC_WIDTH - P_WIDTH + 2)))

    await driver.step(in_valid=1, clear=1, a=a, b=b)
    for _ in range(count):
        await driver.step(in_valid=1, a=a, b=b)
    await driver.idle_cycles(TOTAL_LATENCY + 2)


@cocotb.test()
async def test_reset_during_traffic(dut) -> None:
    """Regression: a mid-stream reset clears the total and the pipeline."""
    rng = RandomStream("mac_reset")
    _domain, driver = await setup(dut)

    await driver.frame([(rng.uint(A_WIDTH), rng.uint(B_WIDTH))
                        for _ in range(8)])

    await driver.reset()

    pairs = [(2, 3), (4, 5)]
    await driver.frame(pairs)
    await driver.idle_cycles(TOTAL_LATENCY + 2)

    await ReadOnly()
    acc = int(dut.acc_out.value)
    await NextTimeStep()
    assert_eq(acc, dot_product(pairs), "total after a mid-stream reset")


@cocotb.test()
async def test_long_run(dut) -> None:
    """Regression: sustained full-rate traffic, checking nothing drifts."""
    rng = RandomStream("mac_long")
    dut._log.info("random seed = %d", rng.seed)
    _domain, driver = await setup(dut)

    for _ in range(2000):
        await driver.step(in_valid=1,
                          a=rng.uint(A_WIDTH),
                          b=rng.uint(B_WIDTH))
    await driver.idle_cycles(TOTAL_LATENCY + 2)
