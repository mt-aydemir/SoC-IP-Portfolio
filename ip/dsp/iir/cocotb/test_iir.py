"""Cocotb regression for iir.

Coverage
    directed   the reset state, unity pass-through, one- and two-sample
               delays through b1 and b2, first-order feedback through a1,
               rounding half up on positive and negative halves, saturation
               that clips instead of wrapping and is flagged, a coefficient
               change, one sample per cycle, and a reset mid-stream
    randomised samples, coefficients, gaps and back-pressure against the
               bit-exact model
    application an RBJ-cookbook low-pass, quantised to COEF_WIDTH: unity DC
               gain, and an impulse response within a rounding-noise bound
               of the same filter computed in floating point

The model is written from the RTL header: the five products summed exactly,
rounded half up at COEF_FRAC, saturated to DATA_WIDTH, and the saturated
value fed back.
"""
from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass, field

import cocotb
from cocotb.triggers import RisingEdge, Timer

from socip import ClockDomain, RandomStream, assert_eq, describe, get_param, to_signed

DATA_WIDTH = get_param("DATA_WIDTH", 16)
COEF_WIDTH = get_param("COEF_WIDTH", 18)
COEF_FRAC = get_param("COEF_FRAC", 16)

CLK_PERIOD_NS = 10.0
ONE = 1 << COEF_FRAC
D_MIN, D_MAX = -(1 << (DATA_WIDTH - 1)), (1 << (DATA_WIDTH - 1)) - 1
C_MIN, C_MAX = -(1 << (COEF_WIDTH - 1)), (1 << (COEF_WIDTH - 1)) - 1
B0, B1, B2, A1, A2 = range(5)


def quantise(value: float) -> int:
    return max(C_MIN, min(C_MAX, int(round(value * ONE))))


@dataclass
class Model:
    coefs: list[int] = field(default_factory=lambda: [0] * 5)
    x1: int = 0
    x2: int = 0
    y1: int = 0
    y2: int = 0

    def reset(self) -> None:
        self.coefs = [0] * 5
        self.x1 = self.x2 = self.y1 = self.y2 = 0

    def sample(self, x: int) -> tuple[int, bool]:
        b0, b1, b2, a1, a2 = self.coefs
        acc = b0 * x + b1 * self.x1 + b2 * self.x2 - a1 * self.y1 - a2 * self.y2
        if COEF_FRAC:
            acc += 1 << (COEF_FRAC - 1)
        q = acc >> COEF_FRAC                      # Python >> floors: arithmetic
        y = max(D_MIN, min(D_MAX, q))
        self.x2, self.x1 = self.x1, x
        self.y2, self.y1 = self.y1, y
        return y, q != y


class Harness:
    def __init__(self, dut, domain: ClockDomain, rng: RandomStream) -> None:
        self.dut = dut
        self.domain = domain
        self.rng = rng
        self.model = Model()
        self.source: deque[int] = deque()
        self.expected: deque[tuple[int, bool]] = deque()
        self.outputs: list[tuple[int, bool]] = []
        self.valid_probability = 1.0
        self.ready_probability = 1.0
        self.coef_writes: deque[tuple[int, int]] = deque()
        self.current: int | None = None
        self.cycle = 0

    def idle(self) -> None:
        d = self.dut
        d.s_valid.value = 0
        d.s_data.value = 0
        d.m_ready.value = 0
        d.coef_wr_en.value = 0
        d.coef_addr.value = 0
        d.coef_data.value = 0
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
        ready = self.rng.boolean(self.ready_probability)
        d.m_ready.value = int(ready)
        write = self.coef_writes.popleft() if self.coef_writes else None
        d.coef_wr_en.value = int(write is not None)
        d.coef_addr.value = write[0] if write else 0
        d.coef_data.value = write[1] if write else 0

        await Timer(CLK_PERIOD_NS / 2, units="ns")
        s_ready = int(d.s_ready.value)
        m_valid = int(d.m_valid.value)
        out = (to_signed(int(d.m_data.value), DATA_WIDTH), bool(int(d.m_saturated.value)))

        await RisingEdge(d.clk)
        self.cycle += 1
        if m_valid and ready:
            if not self.expected:
                raise AssertionError(f"cycle {self.cycle}: output with no input")
            want = self.expected.popleft()
            assert_eq(out[0], want[0], f"cycle {self.cycle}: output {len(self.outputs)}")
            assert_eq(int(out[1]), int(want[1]),
                      f"cycle {self.cycle}: m_saturated for output {len(self.outputs)}")
            self.outputs.append(out)
        if self.current is not None and s_ready:
            self.expected.append(self.model.sample(self.source.popleft()))
            self.current = None
        if write is not None and write[0] < 5:
            self.model.coefs[write[0]] = to_signed(write[1], COEF_WIDTH)

    async def load(self, coefs: list[int]) -> None:
        self.coef_writes.extend((i, c & ((1 << COEF_WIDTH) - 1)) for i, c in enumerate(coefs))
        while self.coef_writes:
            await self.step()

    async def run(self, samples: list[int], limit: int = 200000) -> list[int]:
        start = len(self.outputs)
        self.source.extend(samples)
        begin = self.cycle
        while self.source or self.expected or self.current is not None or self.coef_writes:
            await self.step()
            if self.cycle - begin > limit:
                raise AssertionError("stream did not drain")
        return [y for y, _ in self.outputs[start:]]

    def saturated(self, count: int) -> list[bool]:
        return [s for _, s in self.outputs[-count:]]


async def setup(dut, name: str) -> Harness:
    dut._log.info("iir: DATA_WIDTH=%d COEF_WIDTH=%d COEF_FRAC=%d, %s",
                  DATA_WIDTH, COEF_WIDTH, COEF_FRAC, describe())
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    h = Harness(dut, domain, RandomStream(name))
    await h.reset()
    return h


def rand_samples(rng: RandomStream, n: int) -> list[int]:
    return [to_signed(rng.corner_uint(DATA_WIDTH), DATA_WIDTH) for _ in range(n)]


def assert_same(actual: list, expected: list, message: str) -> None:
    """assert_eq for lists, which it does not compare."""
    assert_eq(len(actual), len(expected), f"{message}: length")
    for i, (a, e) in enumerate(zip(actual, expected)):
        assert_eq(int(a), int(e), f"{message}[{i}]")


def representable(value: float) -> bool:
    return C_MIN <= value * ONE <= C_MAX


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: empty output, zero coefficients give a zero output."""
    h = await setup(dut, "iir_reset")
    assert_eq(int(dut.m_valid.value), 0, "m_valid after reset")
    out = await h.run(rand_samples(h.rng, 20))
    assert_eq(int(any(out)), 0, "output with zero coefficients")


@cocotb.test()
async def test_pass_through_and_delays(dut) -> None:
    """Directed: b0, b1 and b2 of one give x[n], x[n-1] and x[n-2]."""
    h = await setup(dut, "iir_delays")
    if not representable(1.0):
        dut._log.info("1.0 is not representable at COEF_FRAC=%d; skipped", COEF_FRAC)
        return
    x = rand_samples(h.rng, 50)
    for tap in (B0, B1, B2):
        coefs = [0] * 5
        coefs[tap] = ONE
        await h.load(coefs)
        await h.run([0, 0])
        out = await h.run(x)
        assert_same(out[tap:], x[:len(x) - tap], f"b{tap} = 1")


@cocotb.test()
async def test_first_order_feedback(dut) -> None:
    """Directed: b0 = 0.5, a1 = -0.5 give y[n] = (x[n] + y[n-1]) / 2."""
    h = await setup(dut, "iir_feedback")
    await h.load([ONE // 2, 0, 0, -(ONE // 2), 0])
    out = await h.run([D_MAX // 2] + [0] * 20)
    # The impulse response halves every sample, rounded half up each time.
    expected, y = [], 0
    for x in [D_MAX // 2] + [0] * 20:
        y = (x * (ONE // 2) + y * (ONE // 2) + (ONE >> 1 if COEF_FRAC else 0)) >> COEF_FRAC
        expected.append(y)
    assert_same(out, expected, "decaying impulse response")


@cocotb.test()
async def test_rounding_half_up(dut) -> None:
    """Directed: b0 = 0.5 rounds 3 to 2 and -3 to -1, half up."""
    h = await setup(dut, "iir_rounding")
    if COEF_FRAC == 0:
        return
    await h.load([ONE // 2, 0, 0, 0, 0])
    out = await h.run([3, -3, 1, -1, 2, -2])
    assert_same(out, [2, -1, 1, 0, 1, -1], "rounded halves")


@cocotb.test()
async def test_saturation(dut) -> None:
    """Directed: a gain that overflows clips at the rails and is flagged."""
    h = await setup(dut, "iir_saturate")
    await h.load([C_MAX, C_MAX, 0, 0, 0])
    # b0 = b1 = C_MAX (about 2): the first two and the last overflow; the third
    # is C_MAX * (D_MIN + D_MAX), small and negative.
    out = await h.run([D_MAX, D_MAX, D_MIN, D_MIN])
    assert_same([out[0], out[1], out[3]], [D_MAX, D_MAX, D_MIN], "clipped outputs")
    assert_same(h.saturated(4), [1, 1, 0, 1], "m_saturated")


@cocotb.test()
async def test_full_rate(dut) -> None:
    """Directed: one sample per cycle with no back-pressure."""
    h = await setup(dut, "iir_rate")
    await h.load([quantise(0.3), quantise(0.2), quantise(0.1), quantise(-0.4), quantise(0.1)])
    begin = h.cycle
    n = 300
    await h.run(rand_samples(h.rng, n))
    assert_eq(h.cycle - begin, n + 1, f"cycles for {n} samples")


@cocotb.test()
async def test_reset_mid_stream(dut) -> None:
    """Directed: a reset clears the state and the coefficients."""
    h = await setup(dut, "iir_midreset")
    await h.load([quantise(0.5), 0, 0, quantise(-0.5), 0])
    h.ready_probability = 0.4
    h.source.extend(rand_samples(h.rng, 20))
    for _ in range(10):
        await h.step()
    await h.reset()
    h.ready_probability = 1.0
    out = await h.run(rand_samples(h.rng, 10))
    assert_eq(int(any(out)), 0, "zero coefficients after reset")


# ---------------------------------------------------------------------------
# Randomised and application
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_stream(dut) -> None:
    """Randomised: coefficients, samples, gaps and back-pressure."""
    h = await setup(dut, "iir_random")
    for valid_p, ready_p in [(1.0, 1.0), (0.6, 0.9), (0.9, 0.4), (0.5, 0.5)]:
        coefs = [to_signed(h.rng.corner_uint(COEF_WIDTH), COEF_WIDTH) for _ in range(5)]
        h.coef_writes.extend((i, c & ((1 << COEF_WIDTH) - 1)) for i, c in enumerate(coefs))
        h.valid_probability, h.ready_probability = valid_p, ready_p
        await h.run(rand_samples(h.rng, 1500))


@cocotb.test()
async def test_lowpass(dut) -> None:
    """Application: an RBJ low-pass against the same filter in floating point."""
    h = await setup(dut, "iir_lowpass")
    f0, q = 0.05, 1 / math.sqrt(2)
    w0 = 2 * math.pi * f0
    alpha = math.sin(w0) / (2 * q)
    a0 = 1 + alpha
    b = [(1 - math.cos(w0)) / 2 / a0, (1 - math.cos(w0)) / a0, (1 - math.cos(w0)) / 2 / a0]
    a = [-2 * math.cos(w0) / a0, (1 - alpha) / a0]
    if not all(representable(c) for c in b + a):
        dut._log.info("coefficients not representable at COEF_FRAC=%d; skipped", COEF_FRAC)
        return
    coefs = [quantise(c) for c in b + a]
    await h.load(coefs)

    # DC gain: a constant settles to the quantised filter's DC gain, close to
    # one, within a few LSB of rounding.
    level = D_MAX // 2
    out = await h.run([level] * 400)
    dc = level * sum(coefs[:3]) / (ONE + coefs[3] + coefs[4])
    assert_eq(int(abs(out[-1] - dc) <= 4), 1, f"DC settles to {out[-1]}, expected {dc:.1f}")
    assert_eq(int(abs(dc / level - 1) < 0.05), 1, f"DC gain {dc / level:.3f}")

    # Impulse response against the quantised coefficients in floating point.
    await h.run([0] * 400)
    amp = D_MAX // 2
    out = await h.run([amp] + [0] * 199)
    qb = [c / ONE for c in coefs[:3]]
    qa = [c / ONE for c in coefs[3:]]
    xs = [amp] + [0] * 199
    ref, y1, y2, x1, x2 = [], 0.0, 0.0, 0.0, 0.0
    for x in xs:
        y = qb[0] * x + qb[1] * x1 + qb[2] * x2 - qa[0] * y1 - qa[1] * y2
        ref.append(y)
        x2, x1, y2, y1 = x1, x, y1, y
    worst = max(abs(o - r) for o, r in zip(out, ref))
    dut._log.info("impulse response: worst deviation from floating point %.2f LSB", worst)
    # Each output's rounding adds at most half an LSB, and that error then
    # circulates through the recursive part alone, 1 / A(z): the worst case is
    # half an LSB times the L1 norm of 1 / A(z)'s impulse response.
    noise_gain, e1, e2 = 0.0, 0.0, 0.0
    for n in range(2000):
        e = (1.0 if n == 0 else 0.0) - qa[0] * e1 - qa[1] * e2
        noise_gain += abs(e)
        e2, e1 = e1, e
    bound = 0.5 * noise_gain + 0.5
    dut._log.info("rounding bound through 1/A(z): %.2f LSB", bound)
    assert_eq(int(worst <= bound), 1,
              f"deviation {worst:.2f} LSB exceeds the rounding bound {bound:.2f}")
