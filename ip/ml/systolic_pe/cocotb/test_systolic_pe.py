"""Cocotb regression for systolic_pe.

Coverage
    directed   reset state, the one-cycle multiply-accumulate, the activation
               hand-off to the east, the weight shift chain, and the fact that
               a shifted weight has no effect on the arithmetic until it is
               committed
    randomised 2000 corner-biased operand triples checked against a Python
               model of the same arithmetic
    regression the signed extremes, back-to-back commits while data is in
               flight, and a sustained stream with no bubbles

The interesting failures in a processing element are all sign related.
-128 * -128 = +16384 needs seventeen bits to hold a product of two eight-bit
operands, and an implementation that sign-extends the product to the
accumulator width incorrectly still produces plausible-looking numbers for
every operand pair except that one.
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge

from socip import (
    ClockDomain,
    RandomStream,
    assert_eq,
    bits,
    describe,
    get_param,
    sample,
    to_signed,
)

DATA_WIDTH = get_param("DATA_WIDTH", 8)
ACC_WIDTH = get_param("ACC_WIDTH", 32)

CLK_PERIOD_NS = 4.0

DATA_MIN = -(1 << (DATA_WIDTH - 1))
DATA_MAX = (1 << (DATA_WIDTH - 1)) - 1


def model_mac(psum_in: int, weight: int, activation: int) -> int:
    """The arithmetic the element is supposed to implement, in two's complement.

    Everything is done in Python's unbounded integers and truncated at the end,
    so the model wraps exactly where the hardware wraps rather than saturating
    somewhere the hardware does not.
    """
    return bits(psum_in + weight * activation, ACC_WIDTH)


async def bring_up(dut) -> ClockDomain:
    dut._log.info("systolic_pe: DATA_WIDTH=%d, ACC_WIDTH=%d, %s",
                  DATA_WIDTH, ACC_WIDTH, describe())

    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    dut.w_shift.value = 0
    dut.w_commit.value = 0
    dut.w_in.value = 0
    dut.a_in.value = 0
    dut.psum_in.value = 0
    await domain.reset()
    return domain


async def load_weight(dut, domain: ClockDomain, weight: int,
                      commit: bool = True) -> None:
    """Push one weight into the shift register, optionally publishing it."""
    dut.w_in.value = bits(weight, DATA_WIDTH)
    dut.w_shift.value = 1
    await domain.edge()
    dut.w_shift.value = 0
    if commit:
        dut.w_commit.value = 1
        await domain.edge()
        dut.w_commit.value = 0
    await domain.edge()


async def step(dut, domain: ClockDomain, activation: int,
               psum_in: int) -> tuple[int, int]:
    """Apply one operand pair and return (psum_out, a_out) after the edge."""
    dut.a_in.value = bits(activation, DATA_WIDTH)
    dut.psum_in.value = bits(psum_in, ACC_WIDTH)
    await domain.edge()
    psum_out, a_out = await sample(dut.psum_out, dut.a_out)
    await domain.edge()
    return psum_out, a_out


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: every register is cleared and the weight chain is empty."""
    await bring_up(dut)

    psum_out, a_out, w_out = await sample(dut.psum_out, dut.a_out, dut.w_out)
    assert_eq(psum_out, 0, "psum_out after reset")
    assert_eq(a_out, 0, "a_out after reset")
    assert_eq(w_out, 0, "w_out after reset")


@cocotb.test()
async def test_single_mac(dut) -> None:
    """Directed: one multiply-accumulate, one cycle after the operands."""
    domain = await bring_up(dut)
    await load_weight(dut, domain, 3)

    psum_out, a_out = await step(dut, domain, activation=5, psum_in=100)

    assert_eq(to_signed(psum_out, ACC_WIDTH), 115, "100 + 3*5")
    assert_eq(to_signed(a_out, DATA_WIDTH), 5, "activation passed east")


@cocotb.test()
async def test_activation_passes_east_unchanged(dut) -> None:
    """Directed: a_out is a_in delayed by exactly one cycle, weight or no weight."""
    domain = await bring_up(dut)
    await load_weight(dut, domain, -7)

    sequence = [1, -1, DATA_MAX, DATA_MIN, 0, 42 % (DATA_MAX + 1)]
    for value in sequence:
        _psum, a_out = await step(dut, domain, activation=value, psum_in=0)
        assert_eq(to_signed(a_out, DATA_WIDTH), value,
                  f"activation {value} passed east")


@cocotb.test()
async def test_weight_shift_chain(dut) -> None:
    """Directed: w_out is the shift register, one cycle behind w_in."""
    domain = await bring_up(dut)

    for value in (1, -1, DATA_MAX, DATA_MIN, 0):
        dut.w_in.value = bits(value, DATA_WIDTH)
        dut.w_shift.value = 1
        await domain.edge()
        w_out = (await sample(dut.w_out))[0]
        assert_eq(to_signed(w_out, DATA_WIDTH), value,
                  f"weight {value} visible on w_out")
        await domain.edge()

    dut.w_shift.value = 0
    await domain.edge()


@cocotb.test()
async def test_shift_without_commit_does_not_change_the_product(dut) -> None:
    """Directed: the double buffer. This is the reason the block has two registers.

    A weight sitting in the shift chain must have no arithmetic effect, so that
    the next tile can be loaded through the array while the current one is
    still computing.
    """
    domain = await bring_up(dut)
    await load_weight(dut, domain, 2)

    psum_out, _ = await step(dut, domain, activation=10, psum_in=0)
    assert_eq(to_signed(psum_out, ACC_WIDTH), 20, "committed weight is 2")

    # Shift a different weight in without committing it.
    await load_weight(dut, domain, -5, commit=False)

    psum_out, _ = await step(dut, domain, activation=10, psum_in=0)
    assert_eq(to_signed(psum_out, ACC_WIDTH), 20,
              "an uncommitted weight must not reach the multiplier")

    # Publishing it takes effect on the next multiply.
    dut.w_commit.value = 1
    await domain.edge()
    dut.w_commit.value = 0
    await domain.edge()

    psum_out, _ = await step(dut, domain, activation=10, psum_in=0)
    assert_eq(to_signed(psum_out, ACC_WIDTH), -50, "committed weight is now -5")


@cocotb.test()
async def test_signed_extremes(dut) -> None:
    """Directed: the operand pairs that break a sign-extension mistake.

    DATA_MIN * DATA_MIN is positive and needs 2*DATA_WIDTH-1 bits, which is the
    one product that does not fit in the naive signed product width.
    """
    domain = await bring_up(dut)

    cases = [
        (DATA_MIN, DATA_MIN, 0),
        (DATA_MIN, DATA_MAX, 0),
        (DATA_MAX, DATA_MAX, 0),
        (DATA_MIN, -1, 0),
        (-1, DATA_MIN, 0),
        (DATA_MIN, DATA_MIN, -(1 << (ACC_WIDTH - 2))),
        (DATA_MAX, DATA_MIN, (1 << (ACC_WIDTH - 2))),
    ]

    for weight, activation, psum_in in cases:
        await load_weight(dut, domain, weight)
        psum_out, _ = await step(dut, domain, activation, psum_in)
        expected = model_mac(psum_in, weight, activation)
        assert_eq(psum_out, expected,
                  f"psum={psum_in} + {weight}*{activation}")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_mac(dut) -> None:
    """Randomised: corner-biased operands against the Python model."""
    domain = await bring_up(dut)
    rng = RandomStream("systolic_pe")
    dut._log.info("random seed = %d", rng.seed)

    for _ in range(2000):
        weight = rng.corner_sint(DATA_WIDTH)
        activation = rng.corner_sint(DATA_WIDTH)
        # Kept two bits clear of the extremes so the sum cannot legitimately
        # overflow; the overflow assertion in the RTL is watching.
        psum_in = rng.sint(ACC_WIDTH - 2)

        await load_weight(dut, domain, weight)
        psum_out, a_out = await step(dut, domain, activation, psum_in)

        assert_eq(psum_out, model_mac(psum_in, weight, activation),
                  f"{psum_in} + {weight}*{activation}")
        assert_eq(to_signed(a_out, DATA_WIDTH), activation, "activation east")


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_sustained_stream(dut) -> None:
    """Regression: a new operand pair every cycle, no bubbles.

    The element is a fixed one-cycle pipeline, so a stream with no gaps is the
    normal case inside an array rather than a stress case. Results are checked
    against operands applied one cycle earlier.
    """
    domain = await bring_up(dut)
    rng = RandomStream("sustained")
    await load_weight(dut, domain, -3)

    count = 500
    activations = [rng.sint(DATA_WIDTH) for _ in range(count)]
    psums = [rng.sint(ACC_WIDTH - 2) for _ in range(count)]

    # One iteration per clock cycle. The operands for cycle i are driven in the
    # writable region immediately after edge i, so they are captured at edge
    # i+1; the outputs read in the settled phase of that same time step are
    # therefore the ones produced from the operands of cycle i-1.
    for index in range(count):
        await RisingEdge(dut.clk)
        dut.a_in.value = bits(activations[index], DATA_WIDTH)
        dut.psum_in.value = bits(psums[index], ACC_WIDTH)

        psum_out, a_out = await sample(dut.psum_out, dut.a_out)
        if index > 0:
            previous = index - 1
            assert_eq(psum_out, model_mac(psums[previous], -3,
                                          activations[previous]),
                      f"pipelined result {previous}")
            assert_eq(to_signed(a_out, DATA_WIDTH), activations[previous],
                      f"pipelined activation {previous}")

    await domain.edge()


@cocotb.test()
async def test_commit_while_data_in_flight(dut) -> None:
    """Regression: committing a weight affects the very next multiply only.

    An array loads the next tile while the current one computes, so the exact
    cycle a commit takes effect is a correctness property, not a detail.
    """
    domain = await bring_up(dut)
    await load_weight(dut, domain, 1)

    # Stage the replacement without publishing it.
    await load_weight(dut, domain, 4, commit=False)

    dut.a_in.value = bits(9, DATA_WIDTH)
    dut.psum_in.value = 0
    dut.w_commit.value = 1
    await RisingEdge(dut.clk)

    # This edge captured the product formed with the old weight, and the same
    # edge published the new one.
    dut.w_commit.value = 0
    psum_out = (await sample(dut.psum_out))[0]
    assert_eq(to_signed(psum_out, ACC_WIDTH), 9,
              "the multiply in the commit cycle uses the old weight")

    await RisingEdge(dut.clk)
    psum_out = (await sample(dut.psum_out))[0]
    assert_eq(to_signed(psum_out, ACC_WIDTH), 36,
              "the multiply after the commit uses the new weight")
