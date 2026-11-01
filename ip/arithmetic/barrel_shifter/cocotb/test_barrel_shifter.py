"""Cocotb regression for barrel_shifter.

Coverage
    directed   every operation at a shift of zero, at one, at the full width
               minus one, and the sign-extension behaviour of the arithmetic
               right shift
    randomised corner-biased data against every operation and every legal
               shift amount
    regression exhaustive sweep of every (operation, amount) pair, the rotate
               round-trip identity, and the single-bit walk that catches a
               mux stage wired to the wrong power of two

The reference model is written in Python integer arithmetic from the
specification of each operation, so it shares nothing with the design's
``<<``, ``>>`` and ``>>>`` operators beyond the definitions themselves.
"""
from __future__ import annotations

import cocotb

from socip import RandomStream, assert_eq, describe, get_param, settle, to_signed

WIDTH = get_param("WIDTH", 32)

MASK = (1 << WIDTH) - 1
AMT_WIDTH = max(1, (WIDTH - 1).bit_length())
AMT_MASK = (1 << AMT_WIDTH) - 1

OP_SHIFT_LEFT = 0
OP_SHIFT_RIGHT = 1
OP_ARITH_RIGHT = 2
OP_ROTATE_LEFT = 3
OP_ROTATE_RIGHT = 4

OPERATIONS = {
    OP_SHIFT_LEFT: "shift_left",
    OP_SHIFT_RIGHT: "shift_right",
    OP_ARITH_RIGHT: "arith_right",
    OP_ROTATE_LEFT: "rotate_left",
    OP_ROTATE_RIGHT: "rotate_right",
}

# Encodings above the defined set pass the input through unchanged.
UNDEFINED_OPERATIONS = [code for code in range(8) if code not in OPERATIONS]

# Rotates are only well defined over the whole encoding when every
# representable amount is in range, which is the power-of-two case.
WIDTH_IS_POWER_OF_TWO = (1 << AMT_WIDTH) == WIDTH


def model(data: int, amount: int, operation: int) -> int:
    """Reference: the result of one operation, from first principles."""
    data &= MASK
    amount &= AMT_MASK

    if operation == OP_SHIFT_LEFT:
        return (data << amount) & MASK
    if operation == OP_SHIFT_RIGHT:
        return (data >> amount) & MASK
    if operation == OP_ARITH_RIGHT:
        # Python's >> on a negative integer is already an arithmetic shift.
        return (to_signed(data, WIDTH) >> amount) & MASK
    if operation in (OP_ROTATE_LEFT, OP_ROTATE_RIGHT):
        rotate = amount % WIDTH if amount < WIDTH else amount - WIDTH
        if operation == OP_ROTATE_RIGHT:
            rotate = (WIDTH - rotate) % WIDTH
        return ((data << rotate) | (data >> (WIDTH - rotate))) & MASK \
            if rotate else data
    return data


async def apply(dut, data: int, amount: int, operation: int) -> None:
    """Drive one vector and check the result against the model."""
    dut.data_in.value = data & MASK
    dut.amount.value = amount & AMT_MASK
    dut.operation.value = operation
    await settle()

    want = model(data, amount, operation)
    name = OPERATIONS.get(operation, f"undefined({operation})")
    assert_eq(dut.data_out.value, want,
              f"{name} of 0x{data & MASK:X} by {amount & AMT_MASK}")


def announce(dut) -> None:
    dut._log.info("barrel_shifter: WIDTH=%d AMT_WIDTH=%d, %s",
                  WIDTH, AMT_WIDTH, describe())


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_shift_by_zero(dut) -> None:
    """Directed: a shift of zero passes the data through, for every operation.

    Including the rotates, whose implementation has an explicit zero case: a
    rotate by zero would otherwise ask for a shift by the full width, which is
    undefined in the mux structure the operators infer.
    """
    announce(dut)

    for data in (0, 1, MASK, 1 << (WIDTH - 1), 0xA5A5A5A5 & MASK):
        for operation in OPERATIONS:
            await apply(dut, data, 0, operation)


@cocotb.test()
async def test_shift_by_one(dut) -> None:
    """Directed: the smallest non-trivial amount, for every operation."""
    announce(dut)

    for data in (0, 1, 2, MASK, MASK - 1, 1 << (WIDTH - 1)):
        for operation in OPERATIONS:
            await apply(dut, data, 1, operation)


@cocotb.test()
async def test_arithmetic_right_sign_extension(dut) -> None:
    """Directed: the arithmetic right shift replicates the sign bit.

    This is the one operation whose result is not a permutation or a
    zero-filled shift of the input, and the one an implementation gets wrong
    by treating the data as unsigned. A negative value shifted far enough must
    become all-ones, never zero.
    """
    announce(dut)

    negative = 1 << (WIDTH - 1)
    positive = MASK >> 1

    for amount in range(min(WIDTH, 1 << AMT_WIDTH)):
        await apply(dut, negative, amount, OP_ARITH_RIGHT)
        await apply(dut, MASK, amount, OP_ARITH_RIGHT)
        await apply(dut, positive, amount, OP_ARITH_RIGHT)

    # The limit: a negative value shifted by the full width minus one is
    # all-ones, and the logical shift of the same value is not.
    await apply(dut, negative, WIDTH - 1, OP_ARITH_RIGHT)
    await apply(dut, negative, WIDTH - 1, OP_SHIFT_RIGHT)


@cocotb.test()
async def test_undefined_operations_pass_through(dut) -> None:
    """Directed: an unrecognised opcode passes the data through unchanged.

    The encoding is three bits and five operations are defined, so three
    codes are unused. They are specified as a pass-through rather than left
    to chance, which is what keeps the block free of inferred latches.
    """
    announce(dut)

    for operation in UNDEFINED_OPERATIONS:
        for data in (0, 1, MASK, 0x5A5A5A5A & MASK):
            await apply(dut, data, 1, operation)
            await apply(dut, data, AMT_MASK, operation)


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_vectors(dut) -> None:
    """Randomised: corner-biased data, every operation, every legal amount."""
    rng = RandomStream("barrel_shifter")
    dut._log.info("random seed = %d", rng.seed)
    announce(dut)

    codes = list(OPERATIONS) + UNDEFINED_OPERATIONS
    for _ in range(3000):
        await apply(dut,
                    rng.corner_uint(WIDTH),
                    rng.between(0, AMT_MASK),
                    rng.choice(codes))


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_exhaustive_operation_amount(dut) -> None:
    """Regression: every (operation, amount) pair on a fixed data pattern.

    The amount is what selects between the mux stages, so sweeping it
    exhaustively is what proves every stage is wired to the right power of
    two. The data patterns are chosen so that a wrong stage cannot produce the
    right answer by coincidence.
    """
    announce(dut)

    patterns = [0x1, MASK, 1 << (WIDTH - 1), MASK >> 1,
                0xA5A5A5A5 & MASK, 0x5A5A5A5A & MASK]

    for operation in list(OPERATIONS) + UNDEFINED_OPERATIONS:
        for amount in range(1 << AMT_WIDTH):
            for data in patterns:
                await apply(dut, data, amount, operation)


@cocotb.test()
async def test_single_bit_walk(dut) -> None:
    """Regression: one set bit, walked through every position and amount.

    A single bit makes the result of every operation a single known position,
    so a mux stage shifting by the wrong power of two moves it to a place the
    model does not predict. Any other data pattern can mask that error by
    having a bit there already.
    """
    announce(dut)

    for position in range(WIDTH):
        data = 1 << position
        for amount in range(min(WIDTH, 1 << AMT_WIDTH)):
            await apply(dut, data, amount, OP_SHIFT_LEFT)
            await apply(dut, data, amount, OP_SHIFT_RIGHT)
            await apply(dut, data, amount, OP_ROTATE_LEFT)
            await apply(dut, data, amount, OP_ROTATE_RIGHT)


@cocotb.test()
async def test_rotate_round_trip(dut) -> None:
    """Regression: rotating left then right by the same amount is the identity.

    The property that distinguishes a rotate from a shift: no information is
    lost, so the operation is reversible. An implementation that drops the
    wrapped bits passes every directed case where the dropped bits happen to
    be zero and fails this one.
    """
    announce(dut)

    if not WIDTH_IS_POWER_OF_TWO:
        dut._log.info(
            "WIDTH=%d is not a power of two: the round trip is only defined "
            "for amounts below WIDTH", WIDTH)

    rng = RandomStream("barrel_shifter_rotate")
    limit = (1 << AMT_WIDTH) if WIDTH_IS_POWER_OF_TWO else WIDTH

    for _ in range(400):
        data = rng.corner_uint(WIDTH)
        amount = rng.between(0, limit - 1)

        await apply(dut, data, amount, OP_ROTATE_LEFT)
        rotated = int(dut.data_out.value)

        await apply(dut, rotated, amount, OP_ROTATE_RIGHT)
        assert_eq(dut.data_out.value, data & MASK,
                  f"rotate left then right by {amount} restores 0x{data & MASK:X}")

    # A rotate preserves the population count; a shift does not.
    for _ in range(200):
        data = rng.uint(WIDTH)
        amount = rng.between(0, limit - 1)
        await apply(dut, data, amount, OP_ROTATE_LEFT)
        assert_eq(bin(int(dut.data_out.value)).count("1"),
                  bin(data & MASK).count("1"),
                  f"rotate preserves the bit count of 0x{data & MASK:X}")


@cocotb.test()
async def test_output_is_purely_combinational(dut) -> None:
    """Regression: the result depends only on the current inputs."""
    rng = RandomStream("barrel_shifter_stateless")
    announce(dut)

    codes = list(OPERATIONS)
    for _ in range(200):
        data = rng.corner_uint(WIDTH)
        amount = rng.between(0, AMT_MASK)
        operation = rng.choice(codes)

        await apply(dut, data, amount, operation)
        await apply(dut, rng.corner_uint(WIDTH), rng.between(0, AMT_MASK),
                    rng.choice(codes))
        await apply(dut, data, amount, operation)
