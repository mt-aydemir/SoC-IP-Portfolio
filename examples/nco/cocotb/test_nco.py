"""Cocotb regression for the nco integration example.

Coverage
    directed   the first sample is (1, 0); a quarter-turn frequency walks the
               four cardinal points; DC (freq_word = 0) holds still
    randomised random frequencies, positive and negative, against math.cos and
               math.sin over enough samples to pass through every quadrant
    regression the quadrant fold at every boundary, unit amplitude across a
               full turn, a frequency change mid-stream, and back-pressure

The thing under test is the composition, not the blocks: the arithmetic of the
accumulator and the CORDIC is verified in their own suites. What can only go
wrong here is the glue - the phase format shared between them, the quadrant
fold and its negation, and the timing of the fold flag relative to the
iterative CORDIC - and every test is aimed at one of those.
"""
from __future__ import annotations

import math

import cocotb
from cocotb.triggers import NextTimeStep, ReadOnly, RisingEdge

from socip import ClockDomain, RandomStream, describe, get_param, to_signed

WIDTH = get_param("WIDTH", 16)
ITERATIONS = get_param("ITERATIONS", 16)

CLK_PERIOD_NS = 10.0
MASK = (1 << WIDTH) - 1
ONE = 1 << (WIDTH - 2)                 # 1.0 in Q(WIDTH-2)

# The same bound the cordic suite uses, plus a little for the 1/K start
# value's own rounding, which this composition adds on top.
TOLERANCE_LSB = max(8, ITERATIONS // 2 + 6) + 2


async def setup(dut, freq_word: int = 0) -> ClockDomain:
    """Start the clock - once per test - and reset with *freq_word* applied."""
    dut._log.info("nco: WIDTH=%d ITERATIONS=%d tolerance=%d LSB, %s",
                  WIDTH, ITERATIONS, TOLERANCE_LSB, describe())
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    await restart(dut, domain, freq_word)
    return domain


async def restart(dut, domain: ClockDomain, freq_word: int) -> None:
    """Reset back to phase zero with a new frequency word.

    Separate from setup() so a test can restart several times without
    starting a second clock on the same signal.
    """
    dut.freq_word.value = freq_word & MASK
    dut.m_ready.value = 1
    await domain.reset()


async def collect(dut, count: int, ready_rng: RandomStream | None = None
                  ) -> list[tuple[int, int]]:
    """Collect *count* (cos, sin) samples from the output stream."""
    samples: list[tuple[int, int]] = []
    timeout = count * (ITERATIONS + 8) * (4 if ready_rng else 1) + 100
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if ready_rng is not None:
            dut.m_ready.value = int(ready_rng.boolean(0.6))
        await ReadOnly()
        if int(dut.m_valid.value) and int(dut.m_ready.value):
            samples.append((to_signed(int(dut.cos_out.value), WIDTH),
                            to_signed(int(dut.sin_out.value), WIDTH)))
            if len(samples) == count:
                await NextTimeStep()
                dut.m_ready.value = 1
                return samples
    raise AssertionError(f"only {len(samples)} of {count} samples arrived")


def expected(k: int, freq_word: int) -> tuple[float, float]:
    """(cos, sin) of the k-th sample, in LSBs."""
    phase = (k * freq_word) & MASK
    angle = 2.0 * math.pi * phase / (1 << WIDTH)
    return math.cos(angle) * ONE, math.sin(angle) * ONE


def check(samples: list[tuple[int, int]], freq_word: int, start: int = 0,
          context: str = "") -> None:
    for index, (c, s) in enumerate(samples):
        want_c, want_s = expected(start + index, freq_word)
        for name, got, want in (("cos", c, want_c), ("sin", s, want_s)):
            if abs(got - want) > TOLERANCE_LSB:
                phase = ((start + index) * freq_word) & MASK
                raise AssertionError(
                    f"{context}sample {start + index} (phase 0x{phase:X}): "
                    f"{name} expected {want:.1f}, got {got} "
                    f"(error {got - want:.1f} LSB, tolerance {TOLERANCE_LSB})")


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_first_sample(dut) -> None:
    """Directed: the oscillator starts at phase zero, (cos, sin) = (1, 0)."""
    await setup(dut, freq_word=0x1234)
    samples = await collect(dut, 1)
    check(samples, 0x1234, context="first ")


@cocotb.test()
async def test_cardinal_points(dut) -> None:
    """Directed: a quarter turn per sample visits (1,0) (0,1) (-1,0) (0,-1).

    Every sample after the first lands in a different quadrant, so the fold
    and its negation are exercised on every sample, and three of the four
    points are reached only through the fold.
    """
    quarter = 1 << (WIDTH - 2)
    await setup(dut, freq_word=quarter)
    samples = await collect(dut, 8)
    check(samples, quarter, context="quarter turn: ")


@cocotb.test()
async def test_dc(dut) -> None:
    """Directed: a zero frequency word holds the phase still."""
    await setup(dut, freq_word=0)
    samples = await collect(dut, 6)
    check(samples, 0, context="DC: ")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_frequencies(dut) -> None:
    """Randomised: random frequencies in both directions of rotation.

    A negative frequency word is the two's complement of a positive one and
    must rotate the other way: same cosine, negated sine.
    """
    rng = RandomStream("nco")
    dut._log.info("random seed = %d", rng.seed)

    domain = await setup(dut)
    for _ in range(6):
        freq_word = rng.uint(WIDTH)
        await restart(dut, domain, freq_word)
        samples = await collect(dut, 40)
        check(samples, freq_word, context=f"freq 0x{freq_word:X}: ")


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_quadrant_boundaries(dut) -> None:
    """Regression: phases just either side of every quadrant boundary.

    The fold decision changes at +/-pi/2 and at pi, and an off-by-one in the
    bit test that decides it is invisible everywhere except right there. The
    frequency word is chosen so the phase sequence steps one LSB across each
    boundary in turn.
    """
    quarter = 1 << (WIDTH - 2)
    domain = await setup(dut)
    for boundary in (quarter, 2 * quarter, 3 * quarter, 0):
        start_phase = (boundary - 2) & MASK
        # Reach the boundary region with one large step, then cross it in
        # one-LSB steps by switching the frequency word.
        await restart(dut, domain, start_phase)
        await collect(dut, 1)                       # sample at phase 0
        dut.freq_word.value = 1
        # The accumulator advanced by start_phase when the first sample was
        # accepted; from here each sample advances by one LSB.
        samples = await collect(dut, 5)
        for index, (c, s) in enumerate(samples):
            phase = (start_phase + index) & MASK
            angle = 2.0 * math.pi * phase / (1 << WIDTH)
            for name, got, want in (("cos", c, math.cos(angle) * ONE),
                                    ("sin", s, math.sin(angle) * ONE)):
                if abs(got - want) > TOLERANCE_LSB:
                    raise AssertionError(
                        f"boundary 0x{boundary:X}, phase 0x{phase:X}: {name} "
                        f"expected {want:.1f}, got {got}")


@cocotb.test()
async def test_unit_amplitude(dut) -> None:
    """Regression: the amplitude stays at 1.0 all the way round.

    A gain correction applied in the wrong place, or a fold that negates only
    one of the two outputs, distorts the circle without moving any single
    sample far - so the check is on the radius rather than on the components.
    """
    freq_word = (1 << WIDTH) // 64            # 64 samples per turn
    await setup(dut, freq_word=freq_word)
    samples = await collect(dut, 64)
    for index, (c, s) in enumerate(samples):
        radius = math.hypot(c, s)
        if abs(radius - ONE) > 1.5 * TOLERANCE_LSB:
            raise AssertionError(
                f"sample {index}: radius {radius:.1f}, expected {ONE}")


@cocotb.test()
async def test_frequency_change(dut) -> None:
    """Regression: a new frequency word applies from the next phase step.

    The phase is continuous across the change - the accumulator keeps its
    value and only the increment changes - which is the property that makes an
    NCO usable for frequency hopping and carrier tracking.
    """
    f1, f2 = 0x0400 & MASK, 0x1100 & MASK
    await setup(dut, freq_word=f1)
    first = await collect(dut, 10)
    check(first, f1, context="before the change: ")

    # Ten samples at f1 were accepted, so the accumulator holds 10 * f1: the
    # phase of the next sample. The new word applies from the step after it.
    dut.freq_word.value = f2
    second = await collect(dut, 10)

    phase = (10 * f1) & MASK
    for index, (c, s) in enumerate(second):
        angle = 2.0 * math.pi * phase / (1 << WIDTH)
        for name, got, want in (("cos", c, math.cos(angle) * ONE),
                                ("sin", s, math.sin(angle) * ONE)):
            if abs(got - want) > TOLERANCE_LSB:
                raise AssertionError(
                    f"after the change, sample {index} (phase 0x{phase:X}): "
                    f"{name} expected {want:.1f}, got {got}")
        phase = (phase + f2) & MASK


@cocotb.test()
async def test_backpressure(dut) -> None:
    """Regression: a stalling sink loses no samples and repeats none.

    The fold flag is registered when the CORDIC accepts a phase and used when
    the result is presented. Under back-pressure those two moments are far
    apart, so a flag that is overwritten too early negates the wrong sample.
    """
    rng = RandomStream("nco_backpressure")
    dut._log.info("random seed = %d", rng.seed)
    freq_word = 0x2345 & MASK
    await setup(dut, freq_word=freq_word)
    samples = await collect(dut, 40, ready_rng=rng)
    check(samples, freq_word, context="with back-pressure: ")
