"""Cocotb regression for adder.

Coverage
    directed   zero and identity, carry in, the carry-out boundary, the four
               signed overflow corners, and the saturation limits
    randomised corner-biased operand pairs against a reference model written
               from the documented specification
    regression exhaustive sweep at a small width, and the long carry chain
               that a broken propagate/generate structure gets wrong

The reference model is written from the header of the RTL rather than from its
body: it re-derives the sum, the carry out and the overflow rule independently,
so a mistake copied from the design would not be reproduced here.
"""
from __future__ import annotations

import cocotb

from socip import RandomStream, assert_eq, describe, get_param, settle

WIDTH = get_param("WIDTH", 32)
SIGNED = get_param("SIGNED", 0)
SATURATE = get_param("SATURATE", 0)

MASK = (1 << WIDTH) - 1
SIGN_BIT = 1 << (WIDTH - 1)
MOST_POSITIVE = SIGN_BIT - 1
MOST_NEGATIVE = SIGN_BIT


def sign_of(value: int) -> int:
    return (value >> (WIDTH - 1)) & 1


def model(a: int, b: int, carry_in: int) -> tuple[int, int, int]:
    """Reference: (sum, carry_out, overflow) for one operand pair."""
    a &= MASK
    b &= MASK
    carry_in &= 1

    wide = a + b + carry_in
    carry_out = (wide >> WIDTH) & 1
    raw = wide & MASK

    if SIGNED:
        # Two operands of the same sign whose sum has the other sign.
        overflow = int(sign_of(a) == sign_of(b) and sign_of(raw) != sign_of(a))
    else:
        overflow = carry_out

    if not SATURATE or not overflow:
        total = raw
    elif SIGNED:
        # Two negatives can only underflow, two positives only overflow.
        total = MOST_NEGATIVE if sign_of(a) else MOST_POSITIVE
    else:
        total = MASK

    return total, carry_out, overflow


async def apply(dut, a: int, b: int, carry_in: int) -> None:
    """Drive one operand pair and check every output against the model."""
    dut.a.value = a & MASK
    dut.b.value = b & MASK
    dut.carry_in.value = carry_in & 1
    await settle()

    want_sum, want_carry, want_overflow = model(a, b, carry_in)
    context = f"a=0x{a & MASK:X} b=0x{b & MASK:X} cin={carry_in & 1}"
    assert_eq(dut.sum.value, want_sum, f"sum for {context}")
    assert_eq(dut.carry_out.value, want_carry, f"carry_out for {context}")
    assert_eq(dut.overflow.value, want_overflow, f"overflow for {context}")


def announce(dut) -> None:
    dut._log.info("adder: WIDTH=%d SIGNED=%d SATURATE=%d, %s",
                  WIDTH, SIGNED, SATURATE, describe())


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_identities(dut) -> None:
    """Directed: adding zero, and the carry in acting as a plus one."""
    announce(dut)

    await apply(dut, 0, 0, 0)
    await apply(dut, 0, 0, 1)
    for value in (1, 2, 42 & MASK, MASK):
        await apply(dut, value, 0, 0)
        await apply(dut, 0, value, 0)
        await apply(dut, value, 0, 1)


@cocotb.test()
async def test_carry_out_boundary(dut) -> None:
    """Directed: the unsigned wrap point, from just below it to just past it.

    carry_out is defined as the carry out of the top bit and is independent of
    the SIGNED parameter, so it is checked in both interpretations.
    """
    announce(dut)

    await apply(dut, MASK, 0, 0)        # largest unsigned value, no carry
    await apply(dut, MASK, 0, 1)        # wraps to zero, carry out
    await apply(dut, MASK, 1, 0)        # wraps to zero, carry out
    await apply(dut, MASK, MASK, 0)     # wraps to MASK-1, carry out
    await apply(dut, MASK, MASK, 1)     # wraps to MASK, carry out
    await apply(dut, MASK >> 1, 1, 0)   # crosses the sign bit, no carry out


@cocotb.test()
async def test_signed_overflow_corners(dut) -> None:
    """Directed: the four combinations of operand sign at the signed limits.

    Only same-sign pairs can overflow. Opposite signs are included precisely
    to prove the flag stays clear for them: an implementation that tests the
    carry out instead reports overflow all over this list.
    """
    announce(dut)

    cases = [
        (MOST_POSITIVE, 1, 0),              # positive + positive -> overflow
        (MOST_POSITIVE, MOST_POSITIVE, 0),  # positive + positive -> overflow
        (MOST_NEGATIVE, MASK, 0),           # negative + -1       -> overflow
        (MOST_NEGATIVE, MOST_NEGATIVE, 0),  # negative + negative -> overflow
        (MOST_POSITIVE, MOST_NEGATIVE, 0),  # opposite signs, never overflows
        (MOST_POSITIVE, MASK, 0),           # positive + -1, no overflow
        (MOST_NEGATIVE, 1, 0),              # negative + 1,  no overflow
        (MOST_POSITIVE, 0, 1),              # carry in alone crosses the limit
    ]
    for a, b, carry_in in cases:
        await apply(dut, a, b, carry_in)


@cocotb.test()
async def test_saturation_limits(dut) -> None:
    """Directed: an overflowing sum is clamped, not wrapped.

    With SATURATE off the same stimulus proves the opposite property, that the
    result wraps, because the model follows the parameter too.
    """
    announce(dut)

    if not SATURATE:
        dut._log.info("SATURATE=0: the same cases verify wrap-around instead")

    await apply(dut, MASK, MASK, 0)
    await apply(dut, MOST_POSITIVE, MOST_POSITIVE, 0)
    await apply(dut, MOST_NEGATIVE, MOST_NEGATIVE, 0)
    await apply(dut, MOST_NEGATIVE, MOST_NEGATIVE, 1)

    # A sum that only just overflows must clamp to exactly the limit, not to
    # the limit minus the amount by which it overflowed.
    await apply(dut, MOST_POSITIVE, 1, 0)
    await apply(dut, MOST_NEGATIVE, MASK, 0)


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_operands(dut) -> None:
    """Randomised: corner-biased operand pairs against the reference."""
    rng = RandomStream("adder")
    dut._log.info("random seed = %d", rng.seed)
    announce(dut)

    for _ in range(2000):
        a = rng.corner_uint(WIDTH)
        b = rng.corner_uint(WIDTH)
        await apply(dut, a, b, int(rng.boolean()))


@cocotb.test()
async def test_random_same_sign(dut) -> None:
    """Randomised: operands forced to share a sign, where overflow lives.

    Uniform stimulus produces a same-sign pair half the time and an
    *overflowing* same-sign pair far less often than that, so the overflow
    logic is barely exercised by the general random test.
    """
    rng = RandomStream("adder_same_sign")
    dut._log.info("random seed = %d", rng.seed)
    announce(dut)

    for _ in range(600):
        negative = rng.boolean()
        a = rng.uint(WIDTH - 1)
        b = rng.uint(WIDTH - 1)
        if negative:
            a |= SIGN_BIT
            b |= SIGN_BIT
        await apply(dut, a, b, int(rng.boolean()))


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_exhaustive_small(dut) -> None:
    """Regression: every operand pair, at a width small enough to sweep.

    Only runs on a narrow build. Exhaustion is the only way to be sure about
    a carry structure; the randomised tests carry the wide configurations.
    """
    announce(dut)

    if WIDTH > 7:
        dut._log.info("WIDTH=%d is too wide for an exhaustive sweep", WIDTH)
        return

    for a in range(1 << WIDTH):
        for b in range(1 << WIDTH):
            for carry_in in (0, 1):
                await apply(dut, a, b, carry_in)


@cocotb.test()
async def test_carry_chain(dut) -> None:
    """Regression: carries that have to propagate the full width.

    All-ones plus one is the worst case for any carry structure: every bit
    generates a carry into the next. A tree that gets a group boundary wrong
    fails here and nowhere else.
    """
    announce(dut)

    await apply(dut, MASK, 1, 0)
    await apply(dut, MASK, 0, 1)

    # A single one walking up through a field of ones: each position stops the
    # propagation at a different bit.
    for bit in range(WIDTH):
        await apply(dut, MASK, 1 << bit, 0)
        await apply(dut, (1 << bit) - 1, 1, 0)
        await apply(dut, MASK ^ (1 << bit), 1 << bit, 0)


@cocotb.test()
async def test_output_is_purely_combinational(dut) -> None:
    """Regression: the result depends only on the current inputs.

    The block is specified as having no state. Applying a pair, then an
    unrelated pair, then the first pair again must give the same answer both
    times; a latch inferred anywhere in the saturation logic would not.
    """
    rng = RandomStream("adder_stateless")
    announce(dut)

    for _ in range(200):
        a, b = rng.corner_uint(WIDTH), rng.corner_uint(WIDTH)
        carry_in = int(rng.boolean())

        await apply(dut, a, b, carry_in)
        await apply(dut, rng.corner_uint(WIDTH), rng.corner_uint(WIDTH), 1)
        await apply(dut, a, b, carry_in)
