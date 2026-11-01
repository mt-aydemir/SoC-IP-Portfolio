"""Cocotb regression for fir.

Coverage
    directed   the reset state, the impulse response (every coefficient, at
               its extremes), the DC gain, the precision corner where every
               sample and coefficient is the most negative value, one sample
               per cycle under no back-pressure, a coefficient change in the
               middle of a stream, and a reset mid-stream
    randomised samples, coefficients, source gaps and sink back-pressure
               against the reference model, and the same stream against
               numpy.convolve
    application a windowed-sinc low-pass, quantised to COEF_WIDTH, passes a
               low tone and attenuates a high one

The reference model is written from the RTL header's contract, not from the
structure: y[n] is the sum of h[k] * x[n-k], where each h[k] is the value the
coefficient had when sample x[n-k] was accepted. One coroutine runs every
cycle: drive after the edge, settle, sample, and resolve the handshakes the
next edge will see.
"""
from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass, field

import cocotb
import numpy as np
from cocotb.triggers import RisingEdge, Timer

from socip import ClockDomain, RandomStream, assert_eq, describe, get_param, to_signed

TAPS = get_param("TAPS", 16)
DATA_WIDTH = get_param("DATA_WIDTH", 16)
COEF_WIDTH = get_param("COEF_WIDTH", 16)

CLK_PERIOD_NS = 10.0
OUT_WIDTH = DATA_WIDTH + COEF_WIDTH + (TAPS - 1).bit_length()
D_MIN, D_MAX = -(1 << (DATA_WIDTH - 1)), (1 << (DATA_WIDTH - 1)) - 1
C_MIN, C_MAX = -(1 << (COEF_WIDTH - 1)), (1 << (COEF_WIDTH - 1)) - 1


@dataclass
class Model:
    """y[n] = sum h_k(when x[n-k] arrived) * x[n-k]."""

    coefs: list[int] = field(default_factory=lambda: [0] * TAPS)
    history: deque = field(default_factory=lambda: deque(maxlen=TAPS))

    def reset(self) -> None:
        self.coefs = [0] * TAPS
        self.history.clear()

    def sample(self, x: int) -> int:
        self.history.appendleft((x, list(self.coefs)))
        return sum(h[k] * xk for k, (xk, h) in enumerate(self.history))


class Harness:
    def __init__(self, dut, domain: ClockDomain, rng: RandomStream) -> None:
        self.dut = dut
        self.domain = domain
        self.rng = rng
        self.model = Model()
        self.source: deque[int] = deque()
        self.expected: deque[int] = deque()
        self.outputs: list[int] = []
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
        out = to_signed(int(d.m_data.value), OUT_WIDTH)

        await RisingEdge(d.clk)
        self.cycle += 1
        if m_valid and ready:
            if not self.expected:
                raise AssertionError(f"cycle {self.cycle}: output with no input")
            want = self.expected.popleft()
            assert_eq(out, want, f"cycle {self.cycle}: output {len(self.outputs)}")
            self.outputs.append(out)
        if self.current is not None and s_ready:
            # The product uses the coefficients before this edge's write.
            self.expected.append(self.model.sample(self.source.popleft()))
            self.current = None
        if write is not None and write[0] < TAPS:
            self.model.coefs[write[0]] = write[1]

    async def load(self, coefs: list[int]) -> None:
        self.coef_writes.extend(enumerate(coefs))
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
        return self.outputs[start:]


async def setup(dut, name: str) -> Harness:
    dut._log.info("fir: TAPS=%d DATA_WIDTH=%d COEF_WIDTH=%d, %s",
                  TAPS, DATA_WIDTH, COEF_WIDTH, describe())
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    h = Harness(dut, domain, RandomStream(name))
    await h.reset()
    return h


def rand_coefs(rng: RandomStream) -> list[int]:
    return [to_signed(rng.corner_uint(COEF_WIDTH), COEF_WIDTH) for _ in range(TAPS)]


def rand_samples(rng: RandomStream, n: int) -> list[int]:
    return [to_signed(rng.corner_uint(DATA_WIDTH), DATA_WIDTH) for _ in range(n)]


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: empty output, zero coefficients give a zero output."""
    h = await setup(dut, "fir_reset")
    assert_eq(int(dut.m_valid.value), 0, "m_valid after reset")
    out = await h.run(rand_samples(h.rng, 2 * TAPS))
    assert_eq(int(any(out)), 0, "output with zero coefficients")


@cocotb.test()
async def test_impulse_response(dut) -> None:
    """Directed: an impulse reads the coefficients back, extremes included."""
    h = await setup(dut, "fir_impulse")
    coefs = [C_MIN, C_MAX, -1, 1, 0] + rand_coefs(h.rng)
    coefs = coefs[:TAPS]
    await h.load(coefs)
    for amplitude in (1, D_MAX, D_MIN):
        out = await h.run([amplitude] + [0] * TAPS)
        for k in range(TAPS):
            assert_eq(out[k], amplitude * coefs[k], f"impulse {amplitude} tap {k}")
        assert_eq(out[TAPS], 0, "response ends after TAPS samples")


@cocotb.test()
async def test_dc_gain(dut) -> None:
    """Directed: a constant input settles to its value times the coefficient sum."""
    h = await setup(dut, "fir_dc")
    coefs = rand_coefs(h.rng)
    await h.load(coefs)
    out = await h.run([D_MAX] * (3 * TAPS))
    assert_eq(out[-1], D_MAX * sum(coefs), "settled DC output")


@cocotb.test()
async def test_precision_corner(dut) -> None:
    """Directed: most negative times most negative, summed TAPS times, is exact."""
    h = await setup(dut, "fir_corner")
    await h.load([C_MIN] * TAPS)
    out = await h.run([D_MIN] * (2 * TAPS))
    assert_eq(out[-1], TAPS * D_MIN * C_MIN, "largest possible output")
    assert_eq(int(out[-1] < (1 << (OUT_WIDTH - 1))), 1, "fits OUT_WIDTH")


@cocotb.test()
async def test_full_rate(dut) -> None:
    """Directed: one sample per cycle with no back-pressure."""
    h = await setup(dut, "fir_rate")
    await h.load(rand_coefs(h.rng))
    begin = h.cycle
    n = 300
    await h.run(rand_samples(h.rng, n))
    assert_eq(h.cycle - begin, n + 1, f"cycles for {n} samples")


@cocotb.test()
async def test_coefficient_change_mid_stream(dut) -> None:
    """Directed: a write mid-stream blends as the header says, then settles."""
    h = await setup(dut, "fir_reload")
    await h.load(rand_coefs(h.rng))
    h.source.extend(rand_samples(h.rng, 4 * TAPS))
    for _ in range(TAPS):
        await h.step()
    new = rand_coefs(h.rng)
    h.coef_writes.extend(enumerate(new))
    await h.run([])
    await h.run([0] * TAPS)                     # flush the blended history
    out = await h.run([1] + [0] * (TAPS - 1))
    for k in range(TAPS):
        assert_eq(out[k], new[k], f"new impulse response tap {k}")


@cocotb.test()
async def test_reset_mid_stream(dut) -> None:
    """Directed: a reset clears the delay line and the coefficients."""
    h = await setup(dut, "fir_midreset")
    await h.load(rand_coefs(h.rng))
    h.ready_probability = 0.5
    h.source.extend(rand_samples(h.rng, 20))
    for _ in range(10):
        await h.step()
    await h.reset()
    h.ready_probability = 1.0
    assert_eq(int(dut.m_valid.value), 0, "m_valid after reset")
    coefs = rand_coefs(h.rng)
    await h.load(coefs)
    out = await h.run([1] + [0] * (TAPS - 1))
    for k in range(TAPS):
        assert_eq(out[k], coefs[k], f"impulse after reset tap {k}")


# ---------------------------------------------------------------------------
# Randomised and application
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_stream(dut) -> None:
    """Randomised: gaps and back-pressure, against the model and numpy."""
    h = await setup(dut, "fir_random")
    for valid_p, ready_p in [(1.0, 1.0), (0.6, 0.9), (0.9, 0.4), (0.5, 0.5)]:
        coefs = rand_coefs(h.rng)
        await h.load(coefs)
        await h.run([0] * TAPS)                 # flush the old history
        h.valid_probability, h.ready_probability = valid_p, ready_p
        x = rand_samples(h.rng, 1500)
        out = await h.run(x)
        reference = np.convolve(np.array(x, dtype=object), np.array(coefs, dtype=object))
        for n in range(len(x)):
            if out[n] != reference[n]:
                raise AssertionError(f"sample {n}: {out[n]} != numpy {reference[n]}")
        h.valid_probability = h.ready_probability = 1.0


@cocotb.test()
async def test_lowpass_response(dut) -> None:
    """Application: a quantised windowed-sinc low-pass separates two tones."""
    h = await setup(dut, "fir_lowpass")
    cutoff = 0.15                                   # cycles per sample
    n = np.arange(TAPS) - (TAPS - 1) / 2
    taps = 2 * cutoff * np.sinc(2 * cutoff * n) * np.hamming(TAPS)
    taps /= taps.sum()
    scale = C_MAX / max(abs(taps))
    coefs = [int(round(t * scale)) for t in taps]
    await h.load(coefs)

    length = 2048
    t = np.arange(length)
    amp = D_MAX / 2.2
    low, high = 0.03, 0.40
    x = [int(round(amp * (math.sin(2 * math.pi * low * i) + math.sin(2 * math.pi * high * i))))
         for i in t]
    out = np.array(await h.run(x), dtype=float)[TAPS:]
    spectrum = np.abs(np.fft.rfft(out * np.hanning(len(out))))
    freqs = np.fft.rfftfreq(len(out))
    power_low = spectrum[np.argmin(abs(freqs - low))]
    power_high = spectrum[np.argmin(abs(freqs - high))]
    rejection_db = 20 * math.log10(power_low / max(power_high, 1e-12))
    dut._log.info("low-pass rejection of the high tone: %.1f dB", rejection_db)
    assert_eq(int(rejection_db > 20), 1, f"high tone rejected by {rejection_db:.1f} dB")
