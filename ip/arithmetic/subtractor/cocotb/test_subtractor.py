"""Cocotb regression for subtractor.

Coverage
    directed   zero and identity, the borrow in, the unsigned borrow
               boundary, the signed overflow corners and the saturation limits
    randomised corner-biased operand pairs, and pairs forced into the
               opposite-sign arrangement where signed subtraction overflows
    regression exhaustive sweep at a small width, and the borrow chain that a
               broken propagate structure gets wrong

The reference model is written from the specification, not from the RTL: it
computes the exact mathematical difference in Python's unbounded integers and
then asks whether that value was representable. The design arrives at the same
answer through an adder with an inverted operand, so an error in that identity
shows up here as a disagreement rather than being reproduced on both sides.
"""
from __future__ import annotations

import cocotb

from socip import RandomStream, assert_eq, describe, get_param, settle, to_signed

WIDTH = get_param("WIDTH", 32)
SIGNED = get_param("SIGNED", 0)
SATURATE = get_param("SATURATE", 0)

MASK = (1 << WIDTH) - 1
SIGN_BIT = 1 << (WIDTH - 1)
MOST_POSITIVE = SIGN_BIT - 1
MOST_NEGATIVE = SIGN_BIT


def model(a: int, b: int, borrow_in: int) -> tuple[int, int, int]:
    """Reference: (difference, borrow_out, overflow) for one operand pair."""
    a &= MASK
    b &= MASK
    borrow_in &= 1

    # The exact difference under each interpretation, in unbounded integers.
    unsigned_true = a - b - borrow_in
    signed_true = to_signed(a, WIDTH) - to_signed(b, WIDTH) - borrow_in

    raw = unsigned_true & MASK
    borrow_out = int(unsigned_true < 0)

    if SIGNED:
        overflow = int(not -SIGN_BIT <= signed_true <= MOST_POSITIVE)
    else:
        overflow = borrow_out

    if not SATURATE:
        difference = raw
    elif SIGNED:
        if overflow:
            difference = MOST_NEGATIVE if signed_true < 0 else MOST_POSITIVE
        else:
            difference = raw
    else:
        # Unsigned clamps to zero, not to all-ones: the limit that was crossed
        # is the bottom one.
        difference = 0 if borrow_out else raw

    return difference, borrow_out, overflow


async def apply(dut, a: int, b: int, borrow_in: int) -> None:
    """Drive one operand pair and check every output against the model."""
    dut.a.value = a & MASK
    dut.b.value = b & MASK
    dut.borrow_in.value = borrow_in & 1
    await settle()

    want_difference, want_borrow, want_overflow = model(a, b, borrow_in)
    context = f"a=0x{a & MASK:X} b=0x{b & MASK:X} bin={borrow_in & 1}"
    assert_eq(dut.difference.value, want_difference, f"difference for {context}")
    assert_eq(dut.borrow_out.value, want_borrow, f"borrow_out for {context}")
    assert_eq(dut.overflow.value, want_overflow, f"overflow for {context}")


def announce(dut) -> None:
    dut._log.info("subtractor: WIDTH=%d SIGNED=%d SATURATE=%d, %s",
                  WIDTH, SIGNED, SATURATE, describe())


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_identities(dut) -> None:
    """Directed: subtracting zero, subtracting from itself, the borrow in."""
    announce(dut)

    await apply(dut, 0, 0, 0)
    await apply(dut, 0, 0, 1)
    for value in (1, 2, 42 & MASK, MASK, SIGN_BIT):
        await apply(dut, value, 0, 0)        # x - 0 == x
        await apply(dut, value, value, 0)    # x - x == 0
        await apply(dut, value, 0, 1)        # the borrow in as a minus one


@cocotb.test()
async def test_borrow_boundary(dut) -> None:
    """Directed: the point where an unsigned result goes below zero.

    ``borrow_out`` is defined as "the result went below zero" and is
    independent of the SIGNED parameter, so it is checked in both modes.
    """
    announce(dut)

    await apply(dut, 1, 0, 0)       # no borrow
    await apply(dut, 0, 1, 0)       # borrow: wraps to all-ones
    await apply(dut, 0, 0, 1)       # the borrow in alone causes a borrow
    await apply(dut, 1, 1, 1)       # equal operands, borrow in tips it over
    await apply(dut, MASK, MASK, 0)
    await apply(dut, MASK, MASK, 1)


@cocotb.test()
async def test_signed_overflow_corners(dut) -> None:
    """Directed: the operand-sign combinations at the signed limits.

    Only opposite-sign pairs can overflow a subtraction, which is the mirror
    image of the adder's rule. Same-sign pairs are included to prove the flag
    stays clear for them.
    """
    announce(dut)

    cases = [
        (MOST_POSITIVE, MASK, 0),            # +max - (-1) -> overflow
        (MOST_POSITIVE, MOST_NEGATIVE, 0),   # +max - min  -> overflow
        (MOST_NEGATIVE, 1, 0),               # min  - 1    -> overflow
        (MOST_NEGATIVE, MOST_POSITIVE, 0),   # min  - max  -> overflow
        (MOST_NEGATIVE, 0, 1),               # the borrow in alone overflows
        (MOST_POSITIVE, MOST_POSITIVE, 0),   # same sign, never overflows
        (MOST_NEGATIVE, MOST_NEGATIVE, 0),   # same sign, never overflows
        (MOST_POSITIVE, 1, 0),
    ]
    for a, b, borrow_in in cases:
        await apply(dut, a, b, borrow_in)


@cocotb.test()
async def test_saturation_limits(dut) -> None:
    """Directed: an unrepresentable result is clamped to the right limit.

    The unsigned limit is the one the adder cannot supply: an unsigned
    subtraction that goes below zero must clamp to zero, while the adder's
    unsigned saturation clamps to all-ones. A block that forwarded the adder's
    saturation would fail here and nowhere else.
    """
    announce(dut)

    if not SATURATE:
        dut._log.info("SATURATE=0: the same cases verify wrap-around instead")

    await apply(dut, 0, 1, 0)
    await apply(dut, 0, MASK, 0)
    await apply(dut, 1, 2, 0)
    await apply(dut, MOST_NEGATIVE, 1, 0)
    await apply(dut, MOST_POSITIVE, MOST_NEGATIVE, 0)

    # A result that only just crosses the limit must clamp to exactly the
    # limit, not to the limit minus the amount by which it crossed.
    await apply(dut, MOST_NEGATIVE, 0, 1)
    await apply(dut, MOST_POSITIVE, MASK, 0)


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_operands(dut) -> None:
    """Randomised: corner-biased operand pairs against the reference."""
    rng = RandomStream("subtractor")
    dut._log.info("random seed = %d", rng.seed)
    announce(dut)

    for _ in range(2000):
        a = rng.corner_uint(WIDTH)
        b = rng.corner_uint(WIDTH)
        await apply(dut, a, b, int(rng.boolean()))


@cocotb.test()
async def test_random_opposite_sign(dut) -> None:
    """Randomised: operands forced to differ in sign, where overflow lives.

    Uniform stimulus produces an opposite-sign pair half the time and an
    overflowing one far less often than that, so the signed overflow logic is
    barely exercised by the general random test.
    """
    rng = RandomStream("subtractor_opposite_sign")
    dut._log.info("random seed = %d", rng.seed)
    announce(dut)

    for _ in range(600):
        magnitude_a = rng.uint(WIDTH - 1)
        magnitude_b = rng.uint(WIDTH - 1)
        if rng.boolean():
            a, b = magnitude_a | SIGN_BIT, magnitude_b
        else:
            a, b = magnitude_a, magnitude_b | SIGN_BIT
        await apply(dut, a, b, int(rng.boolean()))


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_exhaustive_small(dut) -> None:
    """Regression: every operand pair, at a width small enough to sweep.

    Exhaustion is the only way to be sure about a borrow structure; the
    randomised tests carry the wide configurations.
    """
    announce(dut)

    if WIDTH > 7:
        dut._log.info("WIDTH=%d is too wide for an exhaustive sweep", WIDTH)
        return

    for a in range(1 << WIDTH):
        for b in range(1 << WIDTH):
            for borrow_in in (0, 1):
                await apply(dut, a, b, borrow_in)


@cocotb.test()
async def test_borrow_chain(dut) -> None:
    """Regression: borrows that have to propagate the full width.

    Zero minus one is the worst case for any borrow structure: every bit
    borrows from the next. A tree that gets a group boundary wrong fails here
    and nowhere else.
    """
    announce(dut)

    await apply(dut, 0, 1, 0)
    await apply(dut, 0, 0, 1)

    # A single one walking up through a field of zeros: each position stops the
    # propagation at a different bit.
    for bit in range(WIDTH):
        await apply(dut, 0, 1 << bit, 0)
        await apply(dut, 1 << bit, 1, 0)
        await apply(dut, 1 << bit, (1 << bit) + 1, 0)


@cocotb.test()
async def test_agrees_with_addition(dut) -> None:
    """Regression: a - b equals a + (-b) wherever both are representable.

    An independent cross-check of the inverted-operand identity the design is
    built on, phrased in terms the design does not share.
    """
    rng = RandomStream("subtractor_identity")
    announce(dut)

    for _ in range(500):
        a = rng.corner_uint(WIDTH)
        b = rng.corner_uint(WIDTH)
        await apply(dut, a, b, 0)

        # (a - b) and (a + two's complement of b) are the same bit pattern
        # whenever neither saturates; the model follows the parameters, so the
        # comparison stays valid when SATURATE is set.
        expected, _, _ = model(a, b, 0)
        direct = (a + ((-b) & MASK)) & MASK
        if not SATURATE:
            assert_eq(expected, direct,
                      f"a - b vs a + (-b) for a=0x{a:X} b=0x{b:X}")


@cocotb.test()
async def test_output_is_purely_combinational(dut) -> None:
    """Regression: the result depends only on the current inputs.

    The block is specified as having no state. Applying a pair, then an
    unrelated pair, then the first pair again must give the same answer both
    times; a latch inferred anywhere in the saturation logic would not.
    """
    rng = RandomStream("subtractor_stateless")
    announce(dut)

    for _ in range(200):
        a, b = rng.corner_uint(WIDTH), rng.corner_uint(WIDTH)
        borrow_in = int(rng.boolean())

        await apply(dut, a, b, borrow_in)
        await apply(dut, rng.corner_uint(WIDTH), rng.corner_uint(WIDTH), 1)
        await apply(dut, a, b, borrow_in)
