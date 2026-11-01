"""Cocotb regression for comparator.

Coverage
    directed   equality, the ordering of the sign-bit boundary, the values
               whose ordering differs between the two interpretations, and the
               extremes of the representable range
    randomised corner-biased operand pairs, and pairs that differ in one bit
    regression exhaustive sweep at a small width, the trichotomy property,
               and the antisymmetry of the relations

The reference model compares Python integers obtained by decoding the operands
according to ``SIGNED``, which is a different route to the answer than the
design's: it decides the interpretation once, where the design keeps the bit
patterns and selects between two typed comparisons. A signedness mistake would
have to be made twice, in two different forms, to be missed.
"""
from __future__ import annotations

import cocotb

from socip import RandomStream, assert_eq, describe, get_param, settle, to_signed

WIDTH = get_param("WIDTH", 32)
SIGNED = get_param("SIGNED", 0)

MASK = (1 << WIDTH) - 1
SIGN_BIT = 1 << (WIDTH - 1)
MOST_POSITIVE = SIGN_BIT - 1
MOST_NEGATIVE = SIGN_BIT


def decode(value: int) -> int:
    """Interpret a bit pattern according to the SIGNED parameter."""
    return to_signed(value, WIDTH) if SIGNED else (value & MASK)


def model(a: int, b: int) -> dict[str, int]:
    """Reference: every relation for one operand pair."""
    x, y = decode(a), decode(b)
    return {
        "equal": int(x == y),
        "not_equal": int(x != y),
        "less": int(x < y),
        "less_equal": int(x <= y),
        "greater": int(x > y),
        "greater_equal": int(x >= y),
    }


async def apply(dut, a: int, b: int) -> None:
    """Drive one operand pair and check all six outputs against the model."""
    dut.a.value = a & MASK
    dut.b.value = b & MASK
    await settle()

    want = model(a, b)
    context = f"a=0x{a & MASK:X} b=0x{b & MASK:X}"
    for name, expected in want.items():
        assert_eq(getattr(dut, name).value, expected, f"{name} for {context}")


def announce(dut) -> None:
    dut._log.info("comparator: WIDTH=%d SIGNED=%d, %s",
                  WIDTH, SIGNED, describe())


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_equality(dut) -> None:
    """Directed: equality is interpretation-independent.

    Two bit patterns are equal or they are not; nothing about ``SIGNED``
    changes that, so these cases must pass in both configurations.
    """
    announce(dut)

    for value in (0, 1, MASK, SIGN_BIT, MOST_POSITIVE, 42 & MASK):
        await apply(dut, value, value)

    await apply(dut, 0, 1)
    await apply(dut, MASK, 0)
    await apply(dut, SIGN_BIT, SIGN_BIT - 1)


@cocotb.test()
async def test_interpretation_boundary(dut) -> None:
    """Directed: the pairs whose ordering depends entirely on SIGNED.

    ``0xFF`` is 255 unsigned and -1 signed: the largest value or the smallest,
    according only to how it is read. These are the cases an implementation
    that silently settles on one interpretation gets wrong, and they are the
    reason the mode is a parameter rather than something the caller arranges.
    """
    announce(dut)

    await apply(dut, MASK, 0)                       # -1 vs 0, or max vs min
    await apply(dut, MASK, 1)
    await apply(dut, SIGN_BIT, 0)                   # most negative vs zero
    await apply(dut, SIGN_BIT, MOST_POSITIVE)       # the two extremes
    await apply(dut, MOST_POSITIVE, MOST_NEGATIVE)
    await apply(dut, SIGN_BIT, SIGN_BIT | 1)        # both negative, if signed


@cocotb.test()
async def test_extremes(dut) -> None:
    """Directed: every ordering against the ends of the range."""
    announce(dut)

    for value in (0, 1, MOST_POSITIVE, MOST_NEGATIVE, MASK):
        await apply(dut, value, 0)
        await apply(dut, 0, value)
        await apply(dut, value, MASK)
        await apply(dut, MASK, value)


@cocotb.test()
async def test_adjacent_values(dut) -> None:
    """Directed: pairs one apart, including across the sign-bit boundary.

    An off-by-one in a magnitude comparison is invisible everywhere except
    exactly here.
    """
    announce(dut)

    for value in (0, 1, MOST_POSITIVE - 1, MOST_POSITIVE, MOST_NEGATIVE,
                  MOST_NEGATIVE + 1, MASK - 1):
        await apply(dut, value, (value + 1) & MASK)
        await apply(dut, (value + 1) & MASK, value)


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_operands(dut) -> None:
    """Randomised: corner-biased operand pairs against the reference."""
    rng = RandomStream("comparator")
    dut._log.info("random seed = %d", rng.seed)
    announce(dut)

    for _ in range(2000):
        await apply(dut, rng.corner_uint(WIDTH), rng.corner_uint(WIDTH))


@cocotb.test()
async def test_random_near_misses(dut) -> None:
    """Randomised: pairs differing in exactly one bit.

    Uniform random pairs are almost never close together, so the hardest
    comparisons — the ones decided by a single bit, and above all by the sign
    bit — are the ones uniform stimulus never reaches.
    """
    rng = RandomStream("comparator_near")
    dut._log.info("random seed = %d", rng.seed)
    announce(dut)

    for _ in range(800):
        a = rng.uint(WIDTH)
        b = a ^ (1 << rng.between(0, WIDTH - 1))
        await apply(dut, a, b)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_exhaustive_small(dut) -> None:
    """Regression: every operand pair, at a width small enough to sweep."""
    announce(dut)

    if WIDTH > 7:
        dut._log.info("WIDTH=%d is too wide for an exhaustive sweep", WIDTH)
        return

    for a in range(1 << WIDTH):
        for b in range(1 << WIDTH):
            await apply(dut, a, b)


@cocotb.test()
async def test_trichotomy(dut) -> None:
    """Regression: exactly one of less, equal and greater holds.

    This is the property that catches a signedness mistake without needing to
    know the right answer: an implementation that mixes interpretations can
    report both less and greater for the same pair, and the count is then two
    rather than one. The RTL checks it too, in a concurrent assertion; the
    check is repeated here so the failure is attributed to a stimulus vector.
    """
    rng = RandomStream("comparator_trichotomy")
    announce(dut)

    async def check(a: int, b: int) -> None:
        dut.a.value = a & MASK
        dut.b.value = b & MASK
        await settle()
        total = (int(dut.less.value) + int(dut.equal.value) +
                 int(dut.greater.value))
        assert_eq(total, 1,
                  f"exactly one of less/equal/greater for "
                  f"a=0x{a & MASK:X} b=0x{b & MASK:X}")

    for _ in range(1000):
        await check(rng.corner_uint(WIDTH), rng.corner_uint(WIDTH))

    # The composite relations must agree with their definitions.
    for _ in range(500):
        a, b = rng.corner_uint(WIDTH), rng.corner_uint(WIDTH)
        await apply(dut, a, b)
        assert_eq(int(dut.less_equal.value),
                  int(dut.less.value) | int(dut.equal.value),
                  "less_equal == less | equal")
        assert_eq(int(dut.greater_equal.value),
                  int(dut.greater.value) | int(dut.equal.value),
                  "greater_equal == greater | equal")


@cocotb.test()
async def test_antisymmetry(dut) -> None:
    """Regression: swapping the operands mirrors every relation.

    ``a < b`` must equal ``b > a`` for every pair. A comparator that handles
    one direction correctly and the other through a different path — which is
    what a hand-written implementation tends to grow into — fails here.
    """
    rng = RandomStream("comparator_antisymmetry")
    announce(dut)

    for _ in range(800):
        a, b = rng.corner_uint(WIDTH), rng.corner_uint(WIDTH)

        await apply(dut, a, b)
        forward = {
            "less": int(dut.less.value),
            "greater": int(dut.greater.value),
            "equal": int(dut.equal.value),
        }

        await apply(dut, b, a)
        assert_eq(int(dut.greater.value), forward["less"],
                  f"b > a mirrors a < b for a=0x{a:X} b=0x{b:X}")
        assert_eq(int(dut.less.value), forward["greater"],
                  f"b < a mirrors a > b for a=0x{a:X} b=0x{b:X}")
        assert_eq(int(dut.equal.value), forward["equal"],
                  f"equality is symmetric for a=0x{a:X} b=0x{b:X}")


@cocotb.test()
async def test_output_is_purely_combinational(dut) -> None:
    """Regression: the result depends only on the current inputs."""
    rng = RandomStream("comparator_stateless")
    announce(dut)

    for _ in range(200):
        a, b = rng.corner_uint(WIDTH), rng.corner_uint(WIDTH)

        await apply(dut, a, b)
        await apply(dut, rng.corner_uint(WIDTH), rng.corner_uint(WIDTH))
        await apply(dut, a, b)
