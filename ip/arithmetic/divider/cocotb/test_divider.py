"""Cocotb regression for divider.

Coverage
    directed   exact division, division with a remainder, division by one,
                dividing zero, division by zero, and the signed overflow case
    randomised corner-biased operands against Python's own arithmetic
    regression exhaustive sweep at a small width, back-to-back requests, and
                the identity dividend == quotient*divisor + remainder

The reference is Python integer arithmetic adjusted to the truncated
convention, which is what C and SystemVerilog both use: the quotient rounds
towards zero and the remainder takes the sign of the dividend. Python's own
``//`` and ``%`` floor instead, so -7 // 2 is -4 in Python and -3 here. Using
Python's operators directly would have produced a test that disagreed with
every processor in existence.
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import ReadOnly, RisingEdge

from socip import (
    ClockDomain,
    RandomStream,
    assert_eq,
    describe,
    get_param,
    sample,
    to_signed,
)

WIDTH = get_param("WIDTH", 32)
SIGNED = get_param("SIGNED", 0)

CLK_PERIOD_NS = 10.0
MASK = (1 << WIDTH) - 1
MOST_NEGATIVE = 1 << (WIDTH - 1)


def as_value(raw: int) -> int:
    """Interpret a raw bit pattern according to the SIGNED parameter."""
    return to_signed(raw, WIDTH) if SIGNED else raw


def fits(value: int) -> bool:
    """True if *value* is representable at the configured width and signedness."""
    if SIGNED:
        return -MOST_NEGATIVE <= value <= MOST_NEGATIVE - 1
    return 0 <= value <= MASK


def truncated_divmod(n: int, d: int) -> tuple[int, int]:
    """Divide with the quotient rounded towards zero, as hardware does."""
    quotient = abs(n) // abs(d)
    if (n < 0) != (d < 0):
        quotient = -quotient
    return quotient, n - quotient * d


async def bring_up(dut) -> ClockDomain:
    dut._log.info("divider: WIDTH=%d, SIGNED=%d, %s", WIDTH, SIGNED, describe())
    dut.s_valid.value = 0
    dut.dividend.value = 0
    dut.divisor.value = 0
    dut.m_ready.value = 1
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    await domain.reset()
    return domain


async def divide(dut, dividend: int, divisor: int) -> tuple[int, int, int, int]:
    """Issue one division and return (quotient, remainder, div_by_zero, overflow)."""
    dut.s_valid.value = 1
    dut.dividend.value = dividend & MASK
    dut.divisor.value = divisor & MASK

    while True:
        await ReadOnly()
        if int(dut.s_ready.value) == 1:
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.s_valid.value = 0

    for _ in range(WIDTH + 16):
        await ReadOnly()
        if int(dut.m_valid.value) == 1:
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError(
            f"no result for {dividend} / {divisor} within {WIDTH + 16} cycles")

    quotient, remainder, dbz, ovf = await sample(
        dut.quotient, dut.remainder, dut.div_by_zero, dut.overflow)
    await RisingEdge(dut.clk)
    return quotient, remainder, dbz, ovf


async def check(dut, n: int, d: int) -> None:
    """Divide and compare against the reference."""
    raw_q, raw_r, dbz, ovf = await divide(dut, n, d)

    if d == 0:
        assert_eq(dbz, 1, f"div_by_zero for {n} / 0")
        return
    assert_eq(dbz, 0, f"div_by_zero wrongly set for {n} / {d}")

    if SIGNED and (n & MASK) == MOST_NEGATIVE and (d & MASK) == MASK:
        assert_eq(ovf, 1, "overflow for the most negative value divided by -1")
        return
    assert_eq(ovf, 0, f"overflow wrongly set for {n} / {d}")

    want_q, want_r = truncated_divmod(n, d)
    assert_eq(as_value(raw_q), want_q, f"quotient of {n} / {d}")
    assert_eq(as_value(raw_r), want_r, f"remainder of {n} / {d}")

    # The defining identity. It catches a quotient and remainder that are each
    # plausible but inconsistent with one another.
    assert as_value(raw_q) * d + as_value(raw_r) == n, (
        f"{n} != {as_value(raw_q)}*{d} + {as_value(raw_r)}")


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: ready for a request, no result pending."""
    await bring_up(dut)
    s_ready, m_valid = await sample(dut.s_ready, dut.m_valid)
    assert_eq(s_ready, 1, "s_ready after reset")
    assert_eq(m_valid, 0, "m_valid after reset")


@cocotb.test()
async def test_directed_cases(dut) -> None:
    """Directed: exact division, remainders, identities and edge operands."""
    await bring_up(dut)

    cases = [(100, 10), (100, 7), (1, 1), (0, 5), (255, 1), (7, 3),
             (MASK if not SIGNED else (MOST_NEGATIVE - 1), 1)]
    if SIGNED:
        cases += [(-100, 10), (100, -10), (-100, -10),
                  (-7, 2), (7, -2), (-7, -2), (-1, 1), (1, -1)]

    # Operands are filtered rather than fixed, so the same directed list stays
    # meaningful at every WIDTH the block is built at. A narrow build simply
    # exercises the subset that fits, and the exhaustive test covers the rest.
    applicable = [(n, d) for n, d in cases if fits(n) and fits(d)]
    dut._log.info("%d of %d directed cases fit in %d bits",
                  len(applicable), len(cases), WIDTH)

    for n, d in applicable:
        await check(dut, n, d)


@cocotb.test()
async def test_division_by_zero(dut) -> None:
    """Directed: a zero divisor is flagged and completes without stalling."""
    await bring_up(dut)
    for n in (0, 1, 42):
        await check(dut, n, 0)


@cocotb.test()
async def test_signed_overflow(dut) -> None:
    """Directed: the most negative value divided by -1 has no answer.

    Its magnitude is one larger than the format can hold, so the result must
    be flagged rather than silently wrapped.
    """
    if not SIGNED:
        dut._log.info("unsigned: no overflow case exists")
        return

    await bring_up(dut)
    _q, _r, _dbz, ovf = await divide(dut, MOST_NEGATIVE, MASK)
    assert_eq(ovf, 1, "overflow for the most negative value divided by -1")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_operands(dut) -> None:
    """Randomised: corner-biased operands against the reference."""
    rng = RandomStream("divider")
    dut._log.info("random seed = %d", rng.seed)
    await bring_up(dut)

    for _ in range(150):
        if SIGNED:
            n = rng.corner_sint(WIDTH)
            d = rng.corner_sint(WIDTH)
        else:
            n = rng.corner_uint(WIDTH)
            d = rng.corner_uint(WIDTH)
        await check(dut, n, d)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_exhaustive_small(dut) -> None:
    """Regression: every operand pair, at a width small enough to sweep.

    Only runs when the DUT was elaborated narrow. An exhaustive sweep is the
    only way to be certain about a shift-subtract recurrence; the randomised
    test covers the wide configurations.
    """
    if WIDTH > 6:
        dut._log.info("WIDTH=%d is too wide for an exhaustive sweep", WIDTH)
        return

    await bring_up(dut)
    span = range(-(1 << (WIDTH - 1)), 1 << (WIDTH - 1)) if SIGNED \
        else range(1 << WIDTH)

    for n in span:
        for d in span:
            await check(dut, n, d)


@cocotb.test()
async def test_back_to_back(dut) -> None:
    """Regression: requests issued with no idle cycles between them."""
    rng = RandomStream("back_to_back")
    await bring_up(dut)

    for _ in range(40):
        n = rng.corner_sint(WIDTH) if SIGNED else rng.corner_uint(WIDTH)
        # The divisor has to be drawn in the same interpretation the DUT uses.
        # Drawing an unsigned magnitude and letting the DUT read it as signed
        # makes the reference disagree with a design that is behaving
        # correctly.
        if SIGNED:
            d = rng.between(1, MOST_NEGATIVE - 1)
            if rng.boolean():
                d = -d
        else:
            d = rng.between(1, MASK)
        await check(dut, n, d)
