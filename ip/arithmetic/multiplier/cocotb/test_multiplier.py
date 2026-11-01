"""Cocotb regression for multiplier.

Coverage
    directed   zero and identity, the signed sign combinations, the extreme
               magnitudes where the product needs every bit of its width, and
               the pipeline's reset state and fill behaviour
    randomised corner-biased operand pairs streamed at full rate against a
               reference model, with and without gaps in ``in_valid``
    regression exhaustive sweep at narrow widths, a sustained full-rate run,
               and a mid-stream reset

What is actually being verified here is not the multiplication — a synthesiser
maps ``*`` onto hardware that is correct by construction — but three things
around it that are easy to get wrong: that the signed operands are sign
extended to the full product width before multiplying, that the product and
its valid flag come out of the pipeline together after exactly ``LATENCY``
cycles, and that the pipeline survives ``LATENCY = 1`` where the usual
concatenation-based shift register would be malformed.
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import ReadOnly, RisingEdge

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
SIGNED = get_param("SIGNED", 0)
LATENCY = get_param("LATENCY", 1)

P_WIDTH = A_WIDTH + B_WIDTH
CLK_PERIOD_NS = 5.0

A_MASK = (1 << A_WIDTH) - 1
B_MASK = (1 << B_WIDTH) - 1


def decode(value: int, width: int) -> int:
    """Interpret an operand according to the SIGNED parameter."""
    return to_signed(value, width) if SIGNED else value


def model(a: int, b: int) -> int:
    """Reference: the product as a P_WIDTH bit pattern.

    The product of an m-bit and an n-bit value always fits in m+n bits, in
    both interpretations, so this never loses information and the design is
    specified to report no overflow.
    """
    return bits(decode(a & A_MASK, A_WIDTH) * decode(b & B_MASK, B_WIDTH),
                P_WIDTH)


class Monitor:
    """Records every cycle in which ``out_valid`` is asserted."""

    def __init__(self, dut) -> None:
        self.dut = dut
        self.products: list[int] = []
        self._task = None

    def start(self) -> "Monitor":
        self._task = cocotb.start_soon(self._run())
        return self

    def stop(self) -> None:
        if self._task is not None:
            self._task.kill()
            self._task = None

    async def _run(self) -> None:
        while True:
            await RisingEdge(self.dut.clk)
            await ReadOnly()
            if int(self.dut.rst_n.value) != 1:
                continue
            if int(self.dut.out_valid.value) == 1:
                self.products.append(int(self.dut.product.value))


async def setup(dut) -> tuple[ClockDomain, Monitor]:
    """Bring the DUT up in a known state and start the output monitor."""
    dut._log.info("multiplier: %dx%d SIGNED=%d LATENCY=%d, %s",
                  A_WIDTH, B_WIDTH, SIGNED, LATENCY, describe())

    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    dut.in_valid.value = 0
    dut.a.value = 0
    dut.b.value = 0
    await domain.reset()

    monitor = Monitor(dut).start()
    return domain, monitor


async def push(dut, a: int, b: int) -> None:
    """Present one operand pair for exactly one cycle."""
    dut.a.value = a & A_MASK
    dut.b.value = b & B_MASK
    dut.in_valid.value = 1
    await RisingEdge(dut.clk)
    dut.in_valid.value = 0


async def push_many(dut, pairs, gap=None) -> None:
    """Stream operand pairs, optionally with idle cycles between them."""
    for a, b in pairs:
        dut.a.value = a & A_MASK
        dut.b.value = b & B_MASK
        dut.in_valid.value = 1
        await RisingEdge(dut.clk)
        dut.in_valid.value = 0
        if gap is not None:
            for _ in range(gap()):
                await RisingEdge(dut.clk)


async def drain(domain) -> None:
    """Advance far enough for the pipeline to empty."""
    await domain.cycles(LATENCY + 4)


def check_products(observed: list[int], pairs: list[tuple[int, int]]) -> None:
    """Compare the monitored products against the model, in order."""
    expected = [model(a, b) for a, b in pairs]
    assert_eq(len(observed), len(expected), "number of products produced")
    for index, (want, got) in enumerate(zip(expected, observed)):
        if want != got:
            a, b = pairs[index]
            raise AssertionError(
                f"product {index} for a=0x{a & A_MASK:X} b=0x{b & B_MASK:X}: "
                f"expected 0x{want:X} ({decode(a & A_MASK, A_WIDTH)} * "
                f"{decode(b & B_MASK, B_WIDTH)}), got 0x{got:X}")


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: the output is idle out of reset."""
    domain, _monitor = await setup(dut)

    await ReadOnly()
    assert_eq(dut.out_valid.value, 0, "out_valid after reset")
    assert_eq(dut.product.value, 0, "product after reset")
    await domain.edge()


@cocotb.test()
async def test_latency(dut) -> None:
    """Directed: the product appears exactly LATENCY cycles after the operands.

    Checked by counting edges rather than by waiting for ``out_valid``, so a
    pipeline that is one stage too long or too short fails here instead of
    quietly shifting every result.
    """
    domain, monitor = await setup(dut)

    await push(dut, 3 & A_MASK, 5 & B_MASK)

    # push() consumed the edge on which the operands were captured, so the
    # result is due LATENCY-1 further edges from here.
    for cycle in range(LATENCY - 1):
        await ReadOnly()
        assert_eq(dut.out_valid.value, 0,
                  f"out_valid is still low {cycle + 1} cycle(s) into the pipeline")
        await domain.edge()

    await ReadOnly()
    assert_eq(dut.out_valid.value, 1, f"out_valid after {LATENCY} cycle(s)")
    assert_eq(dut.product.value, model(3, 5), "product of 3 * 5")
    await domain.edge()

    # And it must not repeat: one input, one output.
    await domain.cycles(3)
    assert_eq(len(monitor.products), 1, "exactly one product per operand pair")


@cocotb.test()
async def test_identities(dut) -> None:
    """Directed: multiplying by zero and by one."""
    domain, monitor = await setup(dut)

    pairs = []
    for value in (0, 1, 2, A_MASK, 1 << (A_WIDTH - 1)):
        pairs.append((value, 0))
        pairs.append((0, value & B_MASK))
        pairs.append((value, 1))
        pairs.append((1, value & B_MASK))

    await push_many(dut, pairs)
    await drain(domain)
    check_products(monitor.products, pairs)


@cocotb.test()
async def test_sign_combinations(dut) -> None:
    """Directed: the four sign combinations at the extremes of the range.

    This is the test that fails if the operands are not sign extended to the
    full product width before multiplying. SystemVerilog makes an expression
    unsigned if any operand is unsigned, so a signed multiply written without
    explicit extension silently produces a huge positive product for a
    negative operand — which is correct for three of the four combinations
    below and wrong for the one that matters.
    """
    domain, monitor = await setup(dut)

    a_max = (1 << (A_WIDTH - 1)) - 1
    a_min = 1 << (A_WIDTH - 1)
    b_max = (1 << (B_WIDTH - 1)) - 1
    b_min = 1 << (B_WIDTH - 1)

    pairs = [
        (a_max, b_max),         # + * +
        (a_max, b_min),         # + * -
        (a_min, b_max),         # - * +
        (a_min, b_min),         # - * -, the largest magnitude product
        (A_MASK, B_MASK),       # -1 * -1 signed, max * max unsigned
        (A_MASK, 1),            # -1 * 1
        (a_min, 1),             # most negative * 1
        (a_min, A_MASK & B_MASK),
    ]

    await push_many(dut, pairs)
    await drain(domain)
    check_products(monitor.products, pairs)


@cocotb.test()
async def test_back_to_back(dut) -> None:
    """Directed: a new pair every cycle, with no gaps.

    The block is specified as one multiplication per cycle, so the pipeline
    must hold ``LATENCY`` results in flight without mixing them up.
    """
    domain, monitor = await setup(dut)

    pairs = [(i & A_MASK, (i * 7 + 1) & B_MASK) for i in range(64)]
    await push_many(dut, pairs)
    await drain(domain)
    check_products(monitor.products, pairs)


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_full_rate(dut) -> None:
    """Randomised: corner-biased operands at full rate."""
    rng = RandomStream("multiplier")
    dut._log.info("random seed = %d", rng.seed)
    domain, monitor = await setup(dut)

    pairs = [(rng.corner_uint(A_WIDTH), rng.corner_uint(B_WIDTH))
             for _ in range(500)]
    await push_many(dut, pairs)
    await drain(domain)
    check_products(monitor.products, pairs)


@cocotb.test()
async def test_random_with_gaps(dut) -> None:
    """Randomised: idle cycles between operand pairs.

    A pipeline that advances on every clock rather than only on valid data
    produces the right results at full rate and spurious ones here.
    """
    rng = RandomStream("multiplier_gaps")
    dut._log.info("random seed = %d", rng.seed)
    domain, monitor = await setup(dut)

    pairs = [(rng.corner_uint(A_WIDTH), rng.corner_uint(B_WIDTH))
             for _ in range(300)]
    await push_many(dut, pairs, gap=rng.delay)
    await drain(domain)
    check_products(monitor.products, pairs)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_exhaustive_small(dut) -> None:
    """Regression: every operand pair, at widths small enough to sweep."""
    domain, monitor = await setup(dut)

    if A_WIDTH + B_WIDTH > 12:
        dut._log.info("%dx%d is too wide for an exhaustive sweep",
                      A_WIDTH, B_WIDTH)
        return

    pairs = [(a, b) for a in range(1 << A_WIDTH) for b in range(1 << B_WIDTH)]
    await push_many(dut, pairs)
    await drain(domain)
    check_products(monitor.products, pairs)


@cocotb.test()
async def test_reset_during_traffic(dut) -> None:
    """Regression: a mid-stream reset empties the pipeline.

    Results captured before the reset must not emerge after it: the valid
    pipeline is cleared, so the products in flight are discarded rather than
    appearing against the wrong operands.
    """
    rng = RandomStream("multiplier_reset")
    domain, monitor = await setup(dut)

    await push_many(dut, [(rng.uint(A_WIDTH), rng.uint(B_WIDTH))
                          for _ in range(8)])

    dut.in_valid.value = 0
    await domain.reset()

    await ReadOnly()
    assert_eq(dut.out_valid.value, 0, "out_valid after a mid-stream reset")
    await domain.edge()

    baseline = len(monitor.products)
    pairs = [(2 & A_MASK, 3 & B_MASK)]
    await push_many(dut, pairs)
    await drain(domain)

    assert_eq(len(monitor.products) - baseline, 1,
              "one product after the reset")
    assert_eq(monitor.products[-1], model(2, 3), "product of 2 * 3 after reset")


@cocotb.test()
async def test_long_run(dut) -> None:
    """Regression: sustained full-rate traffic, checking nothing drifts."""
    rng = RandomStream("multiplier_long")
    dut._log.info("random seed = %d", rng.seed)
    domain, monitor = await setup(dut)

    pairs = [(rng.uint(A_WIDTH), rng.uint(B_WIDTH)) for _ in range(2000)]
    await push_many(dut, pairs)
    await drain(domain)
    check_products(monitor.products, pairs)
