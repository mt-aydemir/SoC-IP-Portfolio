"""Cocotb regression for cordic.

Coverage
    directed   sine and cosine at the cardinal angles, magnitude and
               arctangent of known vectors, the convergence-range flag
    randomised angles across the convergence range in rotation mode, and
               random vectors in vectoring mode, compared against math.sin,
               math.cos, math.hypot and math.atan2
    regression accuracy scales with ITERATIONS, and back-to-back operations

Accuracy is asserted as an absolute error bound in LSBs rather than as an
exact match. CORDIC is an approximation: each iteration adds roughly one bit,
and the fixed-point rounding at every step accumulates. A test demanding an
exact result would be testing the reference implementation's rounding, not the
design.
"""
from __future__ import annotations

import math

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

WIDTH = get_param("WIDTH", 16)
ITERATIONS = get_param("ITERATIONS", 16)

CLK_PERIOD_NS = 10.0

# Data is Q(WIDTH-2): 1.0 is 2**(WIDTH-2). Angle is Q(WIDTH-1) scaled by pi.
DATA_ONE = 1 << (WIDTH - 2)
ANGLE_PI = 1 << (WIDTH - 1)

CORDIC_GAIN = 1.6467602581210654

# The iteration adds about one bit of accuracy per step and every step rounds,
# so the error grows roughly with the number of steps. This bound is loose
# enough not to be flaky and tight enough to catch a real defect - a wrong
# table entry or a mis-scaled angle blows through it by orders of magnitude.
TOLERANCE_LSB = max(8, ITERATIONS // 2 + 6)


def to_angle(radians: float) -> int:
    """Convert radians to the block's angle format."""
    return int(round(radians / math.pi * ANGLE_PI))


def from_angle(raw: int) -> float:
    """Convert the block's angle format back to radians."""
    return to_signed(raw, WIDTH) / ANGLE_PI * math.pi


async def bring_up(dut) -> ClockDomain:
    dut._log.info("cordic: WIDTH=%d, ITERATIONS=%d, tolerance=%d LSB, %s",
                  WIDTH, ITERATIONS, TOLERANCE_LSB, describe())
    dut.s_valid.value = 0
    dut.mode_vectoring.value = 0
    dut.x_in.value = 0
    dut.y_in.value = 0
    dut.z_in.value = 0
    dut.m_ready.value = 1
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    await domain.reset()
    return domain


async def operate(dut, vectoring: int, x: int, y: int,
                  z: int) -> tuple[int, int, int, int]:
    """Run one CORDIC operation and return (x, y, z, out_of_range)."""
    dut.s_valid.value = 1
    dut.mode_vectoring.value = vectoring
    dut.x_in.value = x
    dut.y_in.value = y
    dut.z_in.value = z

    while True:
        await ReadOnly()
        if int(dut.s_ready.value) == 1:
            break
        await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.s_valid.value = 0

    for _ in range(ITERATIONS + 16):
        await ReadOnly()
        if int(dut.m_valid.value) == 1:
            break
        await RisingEdge(dut.clk)
    else:
        raise AssertionError("cordic produced no result in time")

    raw_x, raw_y, raw_z, oor = await sample(
        dut.x_out, dut.y_out, dut.z_out, dut.out_of_range)
    await RisingEdge(dut.clk)
    return (to_signed(raw_x, WIDTH), to_signed(raw_y, WIDTH),
            to_signed(raw_z, WIDTH), oor)


async def rotate(dut, radians: float) -> tuple[float, float]:
    """Return (cos, sin) of *radians*, with the CORDIC gain divided out."""
    # Start from (1/K, 0) so the gain lands the result at unit amplitude.
    x0 = int(round(DATA_ONE / CORDIC_GAIN))
    x, y, _z, _oor = await operate(dut, 0, x0, 0, to_angle(radians))
    return x / DATA_ONE, y / DATA_ONE


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: ready for work, no result pending."""
    await bring_up(dut)
    s_ready, m_valid = await sample(dut.s_ready, dut.m_valid)
    assert_eq(s_ready, 1, "s_ready after reset")
    assert_eq(m_valid, 0, "m_valid after reset")


@cocotb.test()
async def test_cardinal_angles(dut) -> None:
    """Directed: sine and cosine at 0, +/-pi/4 and +/-pi/3."""
    await bring_up(dut)

    for radians in (0.0, math.pi / 6, math.pi / 4, math.pi / 3,
                    -math.pi / 6, -math.pi / 4, -math.pi / 3):
        cos_got, sin_got = await rotate(dut, radians)
        cos_err = abs(cos_got - math.cos(radians)) * DATA_ONE
        sin_err = abs(sin_got - math.sin(radians)) * DATA_ONE

        assert cos_err <= TOLERANCE_LSB, (
            f"cos({radians:.4f}): got {cos_got:.5f}, want "
            f"{math.cos(radians):.5f}, error {cos_err:.1f} LSB")
        assert sin_err <= TOLERANCE_LSB, (
            f"sin({radians:.4f}): got {sin_got:.5f}, want "
            f"{math.sin(radians):.5f}, error {sin_err:.1f} LSB")


@cocotb.test()
async def test_vectoring_magnitude_and_angle(dut) -> None:
    """Directed: magnitude and arctangent of known vectors."""
    await bring_up(dut)

    for xf, yf in ((0.5, 0.0), (0.5, 0.5), (0.6, -0.3), (0.25, 0.4)):
        x = int(round(xf * DATA_ONE))
        y = int(round(yf * DATA_ONE))
        got_x, _got_y, got_z, _oor = await operate(dut, 1, x, y, 0)

        want_mag = math.hypot(xf, yf) * CORDIC_GAIN
        want_ang = math.atan2(yf, xf)

        mag_err = abs(got_x / DATA_ONE - want_mag) * DATA_ONE
        ang_err = abs(from_angle(got_z & ((1 << WIDTH) - 1)) - want_ang) \
            / math.pi * ANGLE_PI

        assert mag_err <= TOLERANCE_LSB, (
            f"|({xf}, {yf})|: got {got_x / DATA_ONE:.5f}, want "
            f"{want_mag:.5f}, error {mag_err:.1f} LSB")
        assert ang_err <= TOLERANCE_LSB, (
            f"atan2({yf}, {xf}): error {ang_err:.1f} LSB")


@cocotb.test()
async def test_out_of_range_flag(dut) -> None:
    """Directed: an angle beyond the convergence range is flagged."""
    await bring_up(dut)

    _x, _y, _z, in_range = await operate(dut, 0, DATA_ONE // 2, 0,
                                         to_angle(0.5))
    assert_eq(in_range, 0, "a small angle must not be flagged")

    # 3.0 radians is well past the ~1.7433 rad limit.
    _x, _y, _z, oor = await operate(dut, 0, DATA_ONE // 2, 0, to_angle(3.0))
    assert_eq(oor, 1, "an angle beyond the convergence range must be flagged")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_rotation(dut) -> None:
    """Randomised: angles spread across the convergence range."""
    rng = RandomStream("cordic_rot")
    dut._log.info("random seed = %d", rng.seed)
    await bring_up(dut)

    worst = 0.0
    for _ in range(60):
        radians = rng.between(-1700, 1700) / 1000.0
        cos_got, sin_got = await rotate(dut, radians)
        error = max(abs(cos_got - math.cos(radians)),
                    abs(sin_got - math.sin(radians))) * DATA_ONE
        worst = max(worst, error)
        assert error <= TOLERANCE_LSB, (
            f"rotation by {radians:.4f} rad: error {error:.1f} LSB")

    dut._log.info("worst rotation error over 60 angles: %.1f LSB", worst)


@cocotb.test()
async def test_random_vectoring(dut) -> None:
    """Randomised: vectors in the right half plane, where vectoring converges."""
    rng = RandomStream("cordic_vec")
    dut._log.info("random seed = %d", rng.seed)
    await bring_up(dut)

    worst = 0.0
    for _ in range(60):
        # x must be positive: vectoring converges in the right half plane.
        xf = rng.between(100, 500) / 1000.0
        yf = rng.between(-450, 450) / 1000.0

        got_x, _got_y, _got_z, _oor = await operate(
            dut, 1, int(round(xf * DATA_ONE)), int(round(yf * DATA_ONE)), 0)

        want_mag = math.hypot(xf, yf) * CORDIC_GAIN
        error = abs(got_x / DATA_ONE - want_mag) * DATA_ONE
        worst = max(worst, error)
        assert error <= TOLERANCE_LSB, (
            f"|({xf:.3f}, {yf:.3f})|: error {error:.1f} LSB")

    dut._log.info("worst magnitude error over 60 vectors: %.1f LSB", worst)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_back_to_back(dut) -> None:
    """Regression: operations issued with no idle cycles between them."""
    rng = RandomStream("cordic_b2b")
    await bring_up(dut)

    for _ in range(30):
        radians = rng.between(-1500, 1500) / 1000.0
        cos_got, sin_got = await rotate(dut, radians)
        error = max(abs(cos_got - math.cos(radians)),
                    abs(sin_got - math.sin(radians))) * DATA_ONE
        assert error <= TOLERANCE_LSB, (
            f"back-to-back rotation by {radians:.4f} rad: {error:.1f} LSB")


@cocotb.test()
async def test_pythagorean_identity(dut) -> None:
    """Regression: cos^2 + sin^2 == 1 across the range.

    This catches a systematic scaling error that a per-value comparison can
    miss: if both outputs are scaled by the same wrong factor, each looks
    plausible while their sum of squares does not.
    """
    await bring_up(dut)

    for step in range(-15, 16):
        radians = step / 10.0
        cos_got, sin_got = await rotate(dut, radians)
        magnitude = math.hypot(cos_got, sin_got)
        error = abs(magnitude - 1.0) * DATA_ONE
        assert error <= TOLERANCE_LSB, (
            f"at {radians:.2f} rad the amplitude is {magnitude:.5f}, "
            f"error {error:.1f} LSB")
