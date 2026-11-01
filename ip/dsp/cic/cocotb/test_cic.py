"""Cocotb regression for cic.

Coverage
    directed   the reset state, the DC gain (rate * M) ** N at every rate
               from 1 to MAX_RATE, the impulse response, the full-scale
               corner where the integrators wrap many times over, one input
               sample per cycle, the rule that back-pressure refuses only
               samples that would produce an output, a rate change between
               bursts, and a reset mid-stream
    randomised samples, source gaps and sink back-pressure at random rates
               against the reference model
    independent every output equals the input filtered by N cascaded moving
               sums of length rate * M - computed with numpy, with no
               integrator or comb in sight - sampled at the decimation phase

The reference model follows the register semantics in the RTL header:
pipelined integrators, decimation every rate-th sample on the last
integrator's register, combs at the output rate, all modulo 2**OUT_WIDTH.
"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field

import cocotb
import numpy as np
from cocotb.triggers import RisingEdge, Timer

from socip import ClockDomain, RandomStream, assert_eq, describe, get_param, to_signed

STAGES = get_param("STAGES", 4)
MAX_RATE = get_param("MAX_RATE", 64)
DIFF_DELAY = get_param("DIFF_DELAY", 1)
DATA_WIDTH = get_param("DATA_WIDTH", 16)

CLK_PERIOD_NS = 10.0
OUT_WIDTH = DATA_WIDTH + STAGES * (MAX_RATE * DIFF_DELAY - 1).bit_length()
MASK = (1 << OUT_WIDTH) - 1
D_MIN, D_MAX = -(1 << (DATA_WIDTH - 1)), (1 << (DATA_WIDTH - 1)) - 1


def wrap(v: int) -> int:
    return to_signed(v & MASK, OUT_WIDTH)


@dataclass
class Model:
    integ: list[int] = field(default_factory=lambda: [0] * STAGES)
    delay: list[deque] = field(default_factory=list)
    phase: int = 0

    def __post_init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.integ = [0] * STAGES
        self.delay = [deque([0] * DIFF_DELAY, maxlen=DIFF_DELAY) for _ in range(STAGES)]
        self.phase = 0

    def sample(self, x: int, rate: int) -> int | None:
        due = self.phase + 1 >= rate
        out = None
        if due:
            c = self.integ[-1]
            for s in range(STAGES):
                prev = self.delay[s][-1]
                self.delay[s].appendleft(c)
                c = wrap(c - prev)
            out = c
        old = list(self.integ)
        self.integ[0] = wrap(old[0] + x)
        for s in range(1, STAGES):
            self.integ[s] = wrap(old[s] + old[s - 1])
        self.phase = 0 if due else self.phase + 1
        return out


def boxcar_reference(x: list[int], rate: int) -> list[int]:
    """N moving sums of length rate*M, decimated at the RTL's phase."""
    h = np.array([1], dtype=object)
    for _ in range(STAGES):
        h = np.convolve(h, np.ones(rate * DIFF_DELAY, dtype=object))
    y = np.convolve(np.array(x, dtype=object), h)
    out = []
    for m in range(len(x) // rate):
        n = m * rate + rate - 1 - STAGES
        out.append(int(y[n]) if n >= 0 else 0)
    return out


class Harness:
    def __init__(self, dut, domain: ClockDomain, rng: RandomStream) -> None:
        self.dut = dut
        self.domain = domain
        self.rng = rng
        self.model = Model()
        self.rate = 2
        self.source: deque[int] = deque()
        self.expected: deque[int] = deque()
        self.outputs: list[int] = []
        self.valid_probability = 1.0
        self.ready_probability = 1.0
        self.current: int | None = None
        self.cycle = 0

    def idle(self) -> None:
        self.dut.s_valid.value = 0
        self.dut.s_data.value = 0
        self.dut.m_ready.value = 0
        self.dut.rate.value = self.rate
        self.current = None

    async def reset(self) -> None:
        self.idle()
        await self.domain.reset()
        self.model.reset()
        self.source.clear()
        self.expected.clear()

    async def step(self) -> None:
        d = self.dut
        if self.current is None and self.source and self.rng.boolean(self.valid_probability):
            self.current = self.source[0]
        d.s_valid.value = int(self.current is not None)
        d.s_data.value = self.current if self.current is not None else 0
        d.rate.value = self.rate
        ready = self.rng.boolean(self.ready_probability)
        d.m_ready.value = int(ready)

        await Timer(CLK_PERIOD_NS / 2, units="ns")
        s_ready = int(d.s_ready.value)
        m_valid = int(d.m_valid.value)
        out = to_signed(int(d.m_data.value), OUT_WIDTH)

        due = self.model.phase + 1 >= self.rate
        assert_eq(s_ready, int(not (due and m_valid and not ready)),
                  f"cycle {self.cycle}: s_ready refuses only a due sample")

        await RisingEdge(d.clk)
        self.cycle += 1
        if m_valid and ready:
            if not self.expected:
                raise AssertionError(f"cycle {self.cycle}: output with none due")
            assert_eq(out, self.expected.popleft(), f"cycle {self.cycle}: output "
                      f"{len(self.outputs)} at rate {self.rate}")
            self.outputs.append(out)
        if self.current is not None and s_ready:
            y = self.model.sample(self.source.popleft(), self.rate)
            if y is not None:
                self.expected.append(y)
            self.current = None

    async def run(self, samples: list[int], limit: int = 400000) -> list[int]:
        start = len(self.outputs)
        self.source.extend(samples)
        begin = self.cycle
        while self.source or self.expected or self.current is not None:
            await self.step()
            if self.cycle - begin > limit:
                raise AssertionError("stream did not drain")
        return self.outputs[start:]


async def setup(dut, name: str, rate: int = 2) -> Harness:
    dut._log.info("cic: STAGES=%d MAX_RATE=%d DIFF_DELAY=%d DATA_WIDTH=%d, %s",
                  STAGES, MAX_RATE, DIFF_DELAY, DATA_WIDTH, describe())
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    h = Harness(dut, domain, RandomStream(name))
    h.rate = rate
    await h.reset()
    return h


def rand_samples(rng: RandomStream, n: int) -> list[int]:
    return [to_signed(rng.corner_uint(DATA_WIDTH), DATA_WIDTH) for _ in range(n)]


def rates() -> list[int]:
    return sorted({1, 2, 3, MAX_RATE // 2, MAX_RATE - 1, MAX_RATE} - {0})


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: the output is empty after reset and silence stays silent."""
    h = await setup(dut, "cic_reset")
    assert_eq(int(dut.m_valid.value), 0, "m_valid after reset")
    out = await h.run([0] * 40)
    assert_eq(int(any(out)), 0, "output for zero input")


@cocotb.test()
async def test_dc_gain(dut) -> None:
    """Directed: a constant settles to x * (rate * M) ** N at every rate."""
    for rate in rates():
        h = await setup(dut, f"cic_dc_{rate}", rate)
        for x in (D_MAX, D_MIN):
            settle = rate * (2 * STAGES + 3) * DIFF_DELAY
            out = await h.run([x] * settle)
            assert_eq(out[-1], x * (rate * DIFF_DELAY) ** STAGES,
                      f"DC gain at rate {rate}, input {x}")


@cocotb.test()
async def test_impulse_response(dut) -> None:
    """Directed: an impulse gives the decimated cascaded-boxcar response."""
    for rate in (2, MAX_RATE):
        h = await setup(dut, f"cic_impulse_{rate}", rate)
        x = [D_MAX] + [0] * (rate * (STAGES + 2) * DIFF_DELAY)
        x += [0] * (-len(x) % rate)
        out = await h.run(x)
        ref = boxcar_reference(x, rate)
        for m, (got, want) in enumerate(zip(out, ref)):
            assert_eq(got, want, f"impulse response {m} at rate {rate}")


@cocotb.test()
async def test_full_scale_wrap(dut) -> None:
    """Directed: integrators wrap many times over, the output stays exact."""
    h = await setup(dut, "cic_wrap", MAX_RATE)
    out = await h.run([D_MIN] * (MAX_RATE * 200))
    assert_eq(out[-1], D_MIN * (MAX_RATE * DIFF_DELAY) ** STAGES, "full-scale output")


@cocotb.test()
async def test_full_rate_input(dut) -> None:
    """Directed: one input sample per cycle without back-pressure."""
    h = await setup(dut, "cic_rate", 4)
    begin = h.cycle
    n = 400
    await h.run(rand_samples(h.rng, n))
    assert_eq(h.cycle - begin, n + 1, f"cycles for {n} input samples")


@cocotb.test()
async def test_rate_change_between_bursts(dut) -> None:
    """Directed: a new rate between bursts, each burst checked."""
    h = await setup(dut, "cic_ratechange", 2)
    for rate in (2, MAX_RATE, 3, 1, MAX_RATE // 2):
        h.rate = rate
        x = rand_samples(h.rng, rate * 40)
        await h.run(x)


@cocotb.test()
async def test_reset_mid_stream(dut) -> None:
    """Directed: a reset clears the integrators, combs and phase."""
    h = await setup(dut, "cic_midreset", 3)
    h.ready_probability = 0.3
    h.source.extend(rand_samples(h.rng, 50))
    for _ in range(25):
        await h.step()
    await h.reset()
    h.ready_probability = 1.0
    x = rand_samples(h.rng, 3 * 60)
    out = await h.run(x)
    ref = boxcar_reference(x, 3)
    for m, (got, want) in enumerate(zip(out, ref)):
        assert_eq(got, want, f"output {m} after reset")


# ---------------------------------------------------------------------------
# Randomised and independent
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_flow(dut) -> None:
    """Randomised: rates, gaps and back-pressure against the model."""
    h = await setup(dut, "cic_random", 2)
    for valid_p, ready_p in [(1.0, 1.0), (0.7, 0.8), (1.0, 0.2), (0.5, 0.5)]:
        await h.reset()
        h.rate = h.rng.between(1, MAX_RATE)
        h.valid_probability, h.ready_probability = valid_p, ready_p
        await h.run(rand_samples(h.rng, 3000))


@cocotb.test()
async def test_against_moving_sums(dut) -> None:
    """Independent: outputs equal cascaded moving sums, computed by numpy."""
    h = await setup(dut, "cic_boxcar", 2)
    for rate in rates():
        h.rate = rate
        await h.reset()
        x = rand_samples(h.rng, rate * 150)
        out = await h.run(x)
        ref = boxcar_reference(x, rate)
        assert_eq(len(out), len(ref), f"output count at rate {rate}")
        for m, (got, want) in enumerate(zip(out, ref)):
            assert_eq(got, want, f"output {m} at rate {rate}")
