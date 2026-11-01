"""Cocotb regression for requant_int8.

Coverage
    directed   reset state, the pipeline latency, an exact power-of-two scale,
               the rounding rule at every tie, both clamp edges, a fused ReLU
               expressed through out_min, and a shift of zero
    randomised 4000 corner-biased parameter sets checked bit-for-bit against a
               Python model of the specified arithmetic
    regression back-to-back results at one per cycle with the parameters
               changing on every beat, and the saturation flag

The whole value of this block is that it is bit-exact, so the model is the
specification rather than an approximation: every check is an equality, and
`assert_within` deliberately does not appear anywhere in this file. An
off-by-one in the rounding rule costs measurable accuracy across a network and
is invisible in any test that tolerates a least significant bit.
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
    sample,
    to_signed,
)

ACC_WIDTH = get_param("ACC_WIDTH", 32)
MULT_WIDTH = get_param("MULT_WIDTH", 24)
SHIFT_WIDTH = get_param("SHIFT_WIDTH", 6)
OUT_WIDTH = get_param("OUT_WIDTH", 8)

CLK_PERIOD_NS = 4.0
LATENCY = 3

PROD_WIDTH = ACC_WIDTH + 1 + MULT_WIDTH + 1
MAX_SHIFT = min((1 << SHIFT_WIDTH) - 1, PROD_WIDTH - 1)

OUT_MIN = -(1 << (OUT_WIDTH - 1))
OUT_MAX = (1 << (OUT_WIDTH - 1)) - 1


class Job:
    """One requantisation, with the parameters that go with it."""

    def __init__(self, acc: int, bias: int = 0, mult: int = 1, shift: int = 0,
                 zero_point: int = 0, out_min: int = OUT_MIN,
                 out_max: int = OUT_MAX) -> None:
        self.acc = acc
        self.bias = bias
        self.mult = mult
        self.shift = shift
        self.zero_point = zero_point
        self.out_min = out_min
        self.out_max = out_max

    def __repr__(self) -> str:
        return (f"Job(acc={self.acc}, bias={self.bias}, mult={self.mult}, "
                f"shift={self.shift}, zp={self.zero_point}, "
                f"window=[{self.out_min}, {self.out_max}])")

    def expected(self) -> tuple[int, bool]:
        """The specified result: (output, saturated).

        Python's right shift on a negative integer floors, which is what an
        arithmetic shift does in hardware, so the rounding identity below
        transfers unchanged.
        """
        product = (self.acc + self.bias) * self.mult
        if self.shift == 0:
            adjust = 0
        else:
            half = 1 << (self.shift - 1)
            adjust = (half - 1) if product < 0 else half

        value = ((product + adjust) >> self.shift) + self.zero_point
        if value < self.out_min:
            return self.out_min, True
        if value > self.out_max:
            return self.out_max, True
        return value, False


async def bring_up(dut) -> ClockDomain:
    dut._log.info(
        "requant_int8: ACC_WIDTH=%d MULT_WIDTH=%d SHIFT_WIDTH=%d OUT_WIDTH=%d, %s",
        ACC_WIDTH, MULT_WIDTH, SHIFT_WIDTH, OUT_WIDTH, describe())

    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    dut.in_valid.value = 0
    dut.acc.value = 0
    dut.bias.value = 0
    dut.mult.value = 1
    dut.shift.value = 0
    dut.out_zero_point.value = 0
    dut.out_min.value = bits(OUT_MIN, OUT_WIDTH)
    dut.out_max.value = bits(OUT_MAX, OUT_WIDTH)
    await domain.reset()
    return domain


def drive(dut, job: Job | None) -> None:
    """Present one job, or an idle cycle when *job* is None."""
    if job is None:
        dut.in_valid.value = 0
        return
    dut.in_valid.value = 1
    dut.acc.value = bits(job.acc, ACC_WIDTH)
    dut.bias.value = bits(job.bias, ACC_WIDTH)
    dut.mult.value = bits(job.mult, MULT_WIDTH)
    dut.shift.value = bits(job.shift, SHIFT_WIDTH)
    dut.out_zero_point.value = bits(job.zero_point, OUT_WIDTH)
    dut.out_min.value = bits(job.out_min, OUT_WIDTH)
    dut.out_max.value = bits(job.out_max, OUT_WIDTH)


async def run_jobs(dut, jobs: list[Job]) -> list[tuple[int, int]]:
    """Stream *jobs* back to back and collect (out_data, saturated) for each.

    Results are collected in the settled phase of each cycle, so a job driven
    in cycle i is checked when its result appears in cycle i + LATENCY.
    """
    results: list[tuple[int, int]] = []
    total = len(jobs) + LATENCY + 1

    for index in range(total):
        await RisingEdge(dut.clk)
        drive(dut, jobs[index] if index < len(jobs) else None)

        await ReadOnly()
        if int(dut.out_valid.value) == 1:
            results.append((to_signed(int(dut.out_data.value), OUT_WIDTH),
                            int(dut.saturated.value)))

    await RisingEdge(dut.clk)
    return results


async def check_jobs(dut, jobs: list[Job]) -> None:
    results = await run_jobs(dut, jobs)
    assert_eq(len(results), len(jobs), "number of results produced")

    for index, (job, (got_data, got_sat)) in enumerate(zip(jobs, results)):
        want_data, want_sat = job.expected()
        assert_eq(got_data, want_data, f"job {index} output: {job}")
        assert_eq(got_sat, int(want_sat), f"job {index} saturated flag: {job}")


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: no result is claimed after reset."""
    await bring_up(dut)

    out_valid, out_data, saturated = await sample(
        dut.out_valid, dut.out_data, dut.saturated)
    assert_eq(out_valid, 0, "out_valid after reset")
    assert_eq(out_data, 0, "out_data after reset")
    assert_eq(saturated, 0, "saturated after reset")


@cocotb.test()
async def test_latency(dut) -> None:
    """Directed: the result appears exactly LATENCY cycles after the operands.

    Everything downstream aligns results by counting cycles, so the latency is
    part of the contract rather than an implementation detail.
    """
    domain = await bring_up(dut)

    await domain.edge()
    drive(dut, Job(acc=7))
    await domain.edge()
    drive(dut, None)

    for cycle in range(1, LATENCY + 4):
        valid = (await sample(dut.out_valid))[0]
        if valid:
            assert_eq(cycle, LATENCY, "measured pipeline latency")
            break
        await domain.edge()
    else:
        raise AssertionError("no result appeared within LATENCY + 3 cycles")


@cocotb.test()
async def test_power_of_two_scale(dut) -> None:
    """Directed: mult = 1, shift = s is an exact divide by 2**s."""
    await bring_up(dut)

    jobs = [
        Job(acc=1024, shift=4),      # 64
        Job(acc=-1024, shift=4),     # -64
        Job(acc=100, shift=0),       # saturates high
        Job(acc=0, shift=8),
        Job(acc=127 << 6, shift=6),  # exactly OUT_MAX
        Job(acc=-128 << 6, shift=6),  # exactly OUT_MIN
    ]
    await check_jobs(dut, jobs)


@cocotb.test()
async def test_rounding_ties(dut) -> None:
    """Directed: round to nearest, ties away from zero.

    The tie cases are the whole reason this block has a specified rounding rule
    rather than a truncation: a network requantised with truncation loses about
    half a least significant bit on every layer, and it compounds.
    """
    await bring_up(dut)

    # With shift = 1 the tie is any odd accumulator: 3/2 -> 2, -3/2 -> -2.
    jobs = [
        Job(acc=3, shift=1),     # 1.5 -> 2
        Job(acc=-3, shift=1),    # -1.5 -> -2
        Job(acc=1, shift=1),     # 0.5 -> 1
        Job(acc=-1, shift=1),    # -0.5 -> -1
        Job(acc=2, shift=1),     # 1.0 -> 1
        Job(acc=-2, shift=1),    # -1.0 -> -1
        Job(acc=5, shift=2),     # 1.25 -> 1
        Job(acc=6, shift=2),     # 1.5 -> 2
        Job(acc=7, shift=2),     # 1.75 -> 2
        Job(acc=-5, shift=2),    # -1.25 -> -1
        Job(acc=-6, shift=2),    # -1.5 -> -2
        Job(acc=-7, shift=2),    # -1.75 -> -2
    ]
    await check_jobs(dut, jobs)

    # Spot check two of them against hand-computed values, so a model that
    # agreed with a broken design would still be caught here.
    results = await run_jobs(dut, [Job(acc=-3, shift=1), Job(acc=3, shift=1)])
    assert_eq(results[0][0], -2, "-1.5 rounds away from zero to -2")
    assert_eq(results[1][0], 2, "1.5 rounds away from zero to 2")


@cocotb.test()
async def test_shift_of_zero(dut) -> None:
    """Directed: shift = 0 adds no rounding term.

    The rounding adjustment for a negative product is `half - 1`, which is -1
    when half is zero. Applying it at shift = 0 would drag every negative
    result down by one.
    """
    await bring_up(dut)

    jobs = [Job(acc=value, shift=0) for value in
            (0, 1, -1, 5, -5, OUT_MAX, OUT_MIN)]
    await check_jobs(dut, jobs)


@cocotb.test()
async def test_clamp_edges(dut) -> None:
    """Directed: both ends of the output range saturate rather than wrap."""
    await bring_up(dut)

    jobs = [
        Job(acc=1 << 20, mult=1, shift=0),    # far above OUT_MAX
        Job(acc=-(1 << 20), mult=1, shift=0),  # far below OUT_MIN
        Job(acc=OUT_MAX),                      # exactly at the top, no clamp
        Job(acc=OUT_MIN),                      # exactly at the bottom, no clamp
        Job(acc=OUT_MAX + 1),                  # one past the top
        Job(acc=OUT_MIN - 1),                  # one past the bottom
    ]
    await check_jobs(dut, jobs)


@cocotb.test()
async def test_fused_relu_through_the_window(dut) -> None:
    """Directed: a fused ReLU is out_min raised to the output zero point.

    This is how a quantised graph represents it, and it is why the block has no
    separate activation mode.
    """
    await bring_up(dut)

    zero_point = -5
    jobs = [
        Job(acc=100, zero_point=zero_point, out_min=zero_point),
        Job(acc=-100, zero_point=zero_point, out_min=zero_point),
        Job(acc=0, zero_point=zero_point, out_min=zero_point),
        # ReLU6 in the same quantisation: an upper edge as well.
        Job(acc=1000, zero_point=zero_point, out_min=zero_point, out_max=20),
    ]
    await check_jobs(dut, jobs)

    results = await run_jobs(dut, jobs)
    assert results[1][0] == zero_point, (
        "a negative accumulator under a fused ReLU must land on the zero point")


@cocotb.test()
async def test_zero_multiplier(dut) -> None:
    """Directed: mult = 0 collapses every accumulator onto the zero point."""
    await bring_up(dut)

    jobs = [Job(acc=value, mult=0, shift=10, zero_point=3)
            for value in (0, 1 << 20, -(1 << 20), -1)]
    await check_jobs(dut, jobs)


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_requantisation(dut) -> None:
    """Randomised: corner-biased parameter sets, checked bit for bit."""
    await bring_up(dut)
    rng = RandomStream("requant_int8")
    dut._log.info("random seed = %d", rng.seed)

    jobs = []
    for _ in range(4000):
        shift = rng.between(0, MAX_SHIFT)
        zero_point = rng.corner_sint(OUT_WIDTH)
        low = rng.corner_sint(OUT_WIDTH)
        high = rng.between(low, OUT_MAX)
        jobs.append(Job(
            acc=rng.corner_sint(ACC_WIDTH - 1),
            bias=rng.corner_sint(ACC_WIDTH - 1),
            mult=rng.corner_uint(MULT_WIDTH),
            shift=shift,
            zero_point=zero_point,
            out_min=low,
            out_max=high,
        ))

    await check_jobs(dut, jobs)
    dut._log.info("%d randomised requantisations matched the model", len(jobs))


@cocotb.test()
async def test_random_realistic_scales(dut) -> None:
    """Randomised: the parameter ranges a real quantised layer produces.

    Corner-biased stimulus is good at finding arithmetic mistakes and bad at
    resembling the traffic the block will actually see. A multiplier normalised
    into the top octave with a shift in the twenties is what a host derives
    from a layer's scales, and it is the case where a rounding error would show
    up as accuracy loss rather than as an obvious failure.
    """
    await bring_up(dut)
    rng = RandomStream("realistic")

    jobs = []
    for _ in range(2000):
        shift = rng.between(MULT_WIDTH - 2, min(MAX_SHIFT, MULT_WIDTH + 12))
        jobs.append(Job(
            acc=rng.sint(21),                      # a 16x16 int8 column sum
            bias=rng.sint(18),
            mult=rng.between(1 << (MULT_WIDTH - 2), (1 << MULT_WIDTH) - 1),
            shift=shift,
            zero_point=rng.between(-20, 20),
            out_min=OUT_MIN,
            out_max=OUT_MAX,
        ))

    await check_jobs(dut, jobs)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_full_rate_with_changing_parameters(dut) -> None:
    """Regression: one result per cycle with every parameter changing per beat.

    In the accelerator each column has its own bias, multiplier and shift, so
    the parameters really do change from one result to the next. A pipeline
    that registered them in the wrong stage would pass a constant-parameter
    test and fail here.
    """
    await bring_up(dut)
    rng = RandomStream("full_rate")

    jobs = []
    for index in range(600):
        jobs.append(Job(
            acc=rng.sint(24),
            bias=(index * 977) % 4096 - 2048,
            mult=rng.between(1, (1 << MULT_WIDTH) - 1),
            shift=rng.between(0, MAX_SHIFT),
            zero_point=(index % 61) - 30,
            out_min=OUT_MIN,
            out_max=OUT_MAX,
        ))

    await check_jobs(dut, jobs)


@cocotb.test()
async def test_idle_cycles_produce_no_results(dut) -> None:
    """Regression: gaps in the input stream produce gaps in the output stream."""
    domain = await bring_up(dut)

    jobs = [Job(acc=100, shift=2), Job(acc=-100, shift=2)]
    results = []

    for index in range(2 * len(jobs) + LATENCY + 4):
        await RisingEdge(dut.clk)
        # Present a job on every other cycle only.
        slot = index // 2
        drive(dut, jobs[slot] if (index % 2 == 0 and slot < len(jobs)) else None)

        await ReadOnly()
        if int(dut.out_valid.value) == 1:
            results.append(to_signed(int(dut.out_data.value), OUT_WIDTH))

    await domain.edge()

    assert_eq(len(results), len(jobs), "one result per valid input, no more")
    for index, job in enumerate(jobs):
        assert_eq(results[index], job.expected()[0], f"gapped job {index}")
