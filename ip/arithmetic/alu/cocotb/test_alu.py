"""Cocotb regression for alu.

Coverage
    directed   every opcode on simple operands, the four flags and the rule
               that carry and overflow are cleared by non-arithmetic opcodes,
               multi-word addition and subtraction chained through carry_in,
               the signed and unsigned comparisons at the boundary where they
               disagree, and the undefined opcode
    randomised corner-biased operands against every opcode
    regression exhaustive sweep at a small width, and a check that the result
               depends only on the present inputs

The reference model is written from the opcode table and the flag conventions
stated in the RTL header, in Python integers: it decodes the operands, computes
the mathematical result, and asks whether it was representable. It shares no
structure with the design, which builds everything from one adder and one
shifter, so a mistake in that sharing shows up as a disagreement.
"""
from __future__ import annotations

import cocotb

from socip import RandomStream, assert_eq, describe, get_param, settle, to_signed

WIDTH = get_param("WIDTH", 32)

MASK = (1 << WIDTH) - 1
SIGN_BIT = 1 << (WIDTH - 1)
AMT_WIDTH = max(1, (WIDTH - 1).bit_length())
AMT_MASK = (1 << AMT_WIDTH) - 1

OP_ADD, OP_SUB, OP_AND, OP_OR, OP_XOR, OP_NOT = 0x0, 0x1, 0x2, 0x3, 0x4, 0x5
OP_SLL, OP_SRL, OP_SRA, OP_ROL, OP_ROR = 0x6, 0x7, 0x8, 0x9, 0xA
OP_SLT, OP_SLTU, OP_PASS, OP_PASSB = 0xB, 0xC, 0xD, 0xE
OP_UNDEFINED = 0xF

NAMES = {
    OP_ADD: "ADD", OP_SUB: "SUB", OP_AND: "AND", OP_OR: "OR", OP_XOR: "XOR",
    OP_NOT: "NOT", OP_SLL: "SLL", OP_SRL: "SRL", OP_SRA: "SRA", OP_ROL: "ROL",
    OP_ROR: "ROR", OP_SLT: "SLT", OP_SLTU: "SLTU", OP_PASS: "PASS",
    OP_PASSB: "PASSB", OP_UNDEFINED: "undefined",
}

ARITHMETIC = (OP_ADD, OP_SUB)


def rotate_left(value: int, amount: int) -> int:
    amount %= WIDTH
    if amount == 0:
        return value
    return ((value << amount) | (value >> (WIDTH - amount))) & MASK


def model(a: int, b: int, opcode: int, carry_in: int) -> tuple[int, int, int, int, int]:
    """Reference: (result, Z, N, C, V)."""
    a &= MASK
    b &= MASK
    carry_in &= 1
    sa, sb = to_signed(a, WIDTH), to_signed(b, WIDTH)
    amount = b & AMT_MASK

    carry = 0
    overflow = 0

    if opcode == OP_ADD:
        exact_unsigned = a + b + carry_in
        exact_signed = sa + sb + carry_in
        result = exact_unsigned & MASK
        carry = int(exact_unsigned > MASK)
        overflow = int(not -SIGN_BIT <= exact_signed < SIGN_BIT)
    elif opcode == OP_SUB:
        # ARM convention: carry_in is "no borrow", and so is the carry out.
        borrow_in = 1 - carry_in
        exact_unsigned = a - b - borrow_in
        exact_signed = sa - sb - borrow_in
        result = exact_unsigned & MASK
        carry = int(exact_unsigned >= 0)
        overflow = int(not -SIGN_BIT <= exact_signed < SIGN_BIT)
    elif opcode == OP_AND:
        result = a & b
    elif opcode == OP_OR:
        result = a | b
    elif opcode == OP_XOR:
        result = a ^ b
    elif opcode == OP_NOT:
        result = ~a & MASK
    elif opcode == OP_SLL:
        result = (a << amount) & MASK
    elif opcode == OP_SRL:
        result = a >> amount
    elif opcode == OP_SRA:
        result = (sa >> amount) & MASK
    elif opcode == OP_ROL:
        result = rotate_left(a, amount)
    elif opcode == OP_ROR:
        result = rotate_left(a, (WIDTH - amount % WIDTH) % WIDTH)
    elif opcode == OP_SLT:
        result = int(sa < sb)
    elif opcode == OP_SLTU:
        result = int(a < b)
    elif opcode == OP_PASS:
        result = a
    elif opcode == OP_PASSB:
        result = b
    else:
        result = 0

    zero = int(result == 0)
    negative = (result >> (WIDTH - 1)) & 1
    return result, zero, negative, carry, overflow


async def apply(dut, a: int, b: int, opcode: int, carry_in: int = 0) -> int:
    """Drive one operation, check the result and all four flags."""
    dut.a.value = a & MASK
    dut.b.value = b & MASK
    dut.opcode.value = opcode
    dut.carry_in.value = carry_in & 1
    await settle()

    result, zero, negative, carry, overflow = model(a, b, opcode, carry_in)
    context = (f"{NAMES[opcode]} a=0x{a & MASK:X} b=0x{b & MASK:X} "
               f"cin={carry_in & 1}")
    assert_eq(dut.result.value, result, f"result of {context}")
    assert_eq(dut.flag_zero.value, zero, f"Z after {context}")
    assert_eq(dut.flag_negative.value, negative, f"N after {context}")
    assert_eq(dut.flag_carry.value, carry, f"C after {context}")
    assert_eq(dut.flag_overflow.value, overflow, f"V after {context}")
    return result


def announce(dut) -> None:
    dut._log.info("alu: WIDTH=%d, %s", WIDTH, describe())


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_every_opcode(dut) -> None:
    """Directed: each opcode, including the undefined one, on simple operands."""
    announce(dut)

    operand_pairs = [(0, 0), (1, 1), (5, 3), (3, 5), (MASK, 1),
                     (SIGN_BIT, 1), (0xA5A5A5A5 & MASK, 0x0F0F0F0F & MASK)]
    for opcode in NAMES:
        for a, b in operand_pairs:
            for carry_in in (0, 1):
                await apply(dut, a, b, opcode, carry_in)


@cocotb.test()
async def test_flags_cleared_by_non_arithmetic(dut) -> None:
    """Directed: C and V never survive into a non-arithmetic opcode.

    A consumer must never read a stale carry or overflow left behind by an
    earlier operation, so every opcode other than ADD and SUB clears both,
    even when its operands are the ones that just overflowed an addition.
    """
    announce(dut)

    overflowing = (SIGN_BIT - 1, 1)        # overflows a signed ADD
    for opcode in NAMES:
        if opcode in ARITHMETIC:
            continue
        await apply(dut, *overflowing, OP_ADD, 0)
        await apply(dut, *overflowing, opcode, 1)
        assert_eq(dut.flag_carry.value, 0, f"C cleared by {NAMES[opcode]}")
        assert_eq(dut.flag_overflow.value, 0, f"V cleared by {NAMES[opcode]}")


@cocotb.test()
async def test_carry_convention(dut) -> None:
    """Directed: carry set means "no borrow" for subtraction.

    The ARM and x86 convention rather than the 6502 one. Getting it backwards
    is invisible until a conditional branch on an unsigned comparison goes
    the wrong way.
    """
    announce(dut)

    await apply(dut, 5, 3, OP_SUB, 1)        # no borrow: C = 1
    assert_eq(dut.flag_carry.value, 1, "5 - 3 sets carry (no borrow)")
    await apply(dut, 3, 5, OP_SUB, 1)        # borrow: C = 0
    assert_eq(dut.flag_carry.value, 0, "3 - 5 clears carry (borrow)")
    await apply(dut, 5, 5, OP_SUB, 1)
    assert_eq(dut.flag_zero.value, 1, "5 - 5 sets zero")
    assert_eq(dut.flag_carry.value, 1, "5 - 5 sets carry")


@cocotb.test()
async def test_multiword_chaining(dut) -> None:
    """Directed: a double-width add and subtract built from two operations.

    The carry out of the low word, fed back as carry_in for the high word, is
    the reason ADD and SUB take a carry at all. Subtraction has to chain the
    same way, with carry read as "no borrow", or a double-width subtraction
    whose low word borrows comes out one too large.
    """
    announce(dut)
    rng = RandomStream("alu_multiword")
    dut._log.info("random seed = %d", rng.seed)

    for _ in range(200):
        x = rng.uint(2 * WIDTH)
        y = rng.uint(2 * WIDTH)
        x_lo, x_hi = x & MASK, x >> WIDTH
        y_lo, y_hi = y & MASK, y >> WIDTH

        lo = await apply(dut, x_lo, y_lo, OP_ADD, 0)
        carry = int(dut.flag_carry.value)
        hi = await apply(dut, x_hi, y_hi, OP_ADD, carry)
        assert_eq((hi << WIDTH) | lo, (x + y) & ((1 << (2 * WIDTH)) - 1),
                  f"double-width 0x{x:X} + 0x{y:X}")

        lo = await apply(dut, x_lo, y_lo, OP_SUB, 1)
        carry = int(dut.flag_carry.value)
        hi = await apply(dut, x_hi, y_hi, OP_SUB, carry)
        assert_eq((hi << WIDTH) | lo, (x - y) & ((1 << (2 * WIDTH)) - 1),
                  f"double-width 0x{x:X} - 0x{y:X}")


@cocotb.test()
async def test_comparisons_disagree_at_the_sign_bit(dut) -> None:
    """Directed: the pairs where signed and unsigned less-than differ.

    SLT is "the sign of the difference, corrected for overflow" - N XOR V -
    and the overflow correction only matters for operands far apart across the
    sign boundary. Those are the cases here.
    """
    announce(dut)

    cases = [
        (SIGN_BIT, 0),                  # most negative vs zero
        (SIGN_BIT, SIGN_BIT - 1),       # the two extremes: SUB overflows
        (SIGN_BIT - 1, SIGN_BIT),
        (MASK, 1),                      # -1 vs 1
        (1, MASK),
        (0, 0),
    ]
    for a, b in cases:
        for carry_in in (0, 1):          # the comparisons ignore carry_in
            await apply(dut, a, b, OP_SLT, carry_in)
            await apply(dut, a, b, OP_SLTU, carry_in)


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_operations(dut) -> None:
    """Randomised: corner-biased operands against every opcode."""
    rng = RandomStream("alu")
    dut._log.info("random seed = %d", rng.seed)
    announce(dut)

    opcodes = list(NAMES)
    for _ in range(4000):
        await apply(dut,
                    rng.corner_uint(WIDTH),
                    rng.corner_uint(WIDTH),
                    rng.choice(opcodes),
                    int(rng.boolean()))


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_exhaustive_small(dut) -> None:
    """Regression: every operand pair and opcode, at a width small enough."""
    announce(dut)

    if WIDTH > 5:
        dut._log.info("WIDTH=%d is too wide for an exhaustive sweep", WIDTH)
        return

    for opcode in NAMES:
        for a in range(1 << WIDTH):
            for b in range(1 << WIDTH):
                for carry_in in (0, 1):
                    await apply(dut, a, b, opcode, carry_in)


@cocotb.test()
async def test_output_is_purely_combinational(dut) -> None:
    """Regression: the result depends only on the current inputs."""
    rng = RandomStream("alu_stateless")
    announce(dut)

    opcodes = list(NAMES)
    for _ in range(300):
        vector = (rng.corner_uint(WIDTH), rng.corner_uint(WIDTH),
                  rng.choice(opcodes), int(rng.boolean()))
        await apply(dut, *vector)
        await apply(dut, rng.corner_uint(WIDTH), rng.corner_uint(WIDTH),
                    rng.choice(opcodes), int(rng.boolean()))
        await apply(dut, *vector)
