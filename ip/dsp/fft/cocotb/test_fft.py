"""Cocotb regression for fft.

Coverage
    directed   the reset state, an impulse (flat spectrum), DC (all energy in
               bin 0), a single tone in every bin, the inverse transform, the
               frame timing (N load, N/2 * log2 N compute, N unload cycles),
               m_last on bin N-1, m_overflow for each butterfly output
               saturating alone (in constructed frames) and not for a quiet
               frame, and a reset mid-frame
    randomised frames of random full-scale samples with input gaps and output
               back-pressure, forward and inverse, against the bit-exact model
    independent every frame's result within a rounding bound of numpy.fft,
               scaled by 1/N

The bit-exact model is written from the RTL header's algorithm: bit-reversed
loading, decimation-in-time butterflies in place, Q1.15 twiddles from the
quarter-wave formula in scripts/gen_twiddle.py, rounding half up after the
complex product and after each halving, saturation per butterfly output.
"""
from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass

import cocotb
import numpy as np
from cocotb.triggers import RisingEdge, Timer

from socip import ClockDomain, RandomStream, assert_eq, describe, get_param, to_signed

N_LOG2 = get_param("N_LOG2", 6)
DATA_WIDTH = get_param("DATA_WIDTH", 16)

CLK_PERIOD_NS = 10.0
N = 1 << N_LOG2
D_MIN, D_MAX = -(1 << (DATA_WIDTH - 1)), (1 << (DATA_WIDTH - 1)) - 1
QUARTER = [round(32767 * math.cos(2 * math.pi * i / 1024)) for i in range(257)]


def twiddle(k: int) -> tuple[int, int]:
    if k <= 256:
        return QUARTER[k], QUARTER[256 - k]
    return -QUARTER[512 - k], QUARTER[k - 256]


def bit_reverse(a: int) -> int:
    return int(format(a, f"0{N_LOG2}b")[::-1], 2)


def saturate(v: int) -> tuple[int, bool]:
    s = max(D_MIN, min(D_MAX, v))
    return s, s != v


def fft_model(re: list[int], im: list[int], inverse: bool) -> tuple[list[int], list[int], bool]:
    mr, mi, clips = fft_model_clips(re, im, inverse)
    return mr, mi, any(clips)


def fft_model_clips(re: list[int], im: list[int], inverse: bool):
    """The model, also counting saturations per butterfly output:
    clips = [x[i0].re, x[i0].im, x[i1].re, x[i1].im]."""
    mr, mi = [0] * N, [0] * N
    for n in range(N):
        mr[bit_reverse(n)], mi[bit_reverse(n)] = re[n], im[n]
    clips = [0, 0, 0, 0]
    for s in range(N_LOG2):
        half = 1 << s
        for j in range(N // 2):
            pos = j & (half - 1)
            i0 = ((j >> s) << (s + 1)) | pos
            i1 = i0 | half
            c, sn = twiddle((pos << (N_LOG2 - 1 - s)) << (10 - N_LOG2))
            wr, wi = c, (sn if inverse else -sn)
            ar, ai, br, bi = mr[i0], mi[i0], mr[i1], mi[i1]
            tr = (br * wr - bi * wi + (1 << 14)) >> 15
            ti = (br * wi + bi * wr + (1 << 14)) >> 15
            outs = [saturate((x + 1) >> 1) for x in (ar + tr, ai + ti, ar - tr, ai - ti)]
            for c, (_, clipped) in enumerate(outs):
                clips[c] += clipped
            mr[i0], mi[i0], mr[i1], mi[i1] = (v for v, _ in outs)
    return mr, mi, clips


@dataclass
class Frame:
    re: list[int]
    im: list[int]
    inverse: bool = False


class Harness:
    def __init__(self, dut, domain: ClockDomain, rng: RandomStream) -> None:
        self.dut = dut
        self.domain = domain
        self.rng = rng
        self.source: deque[tuple[int, int, bool]] = deque()
        self.expected: deque[tuple[int, int, bool, bool]] = deque()
        self.results: list[tuple[list[int], list[int], bool]] = []
        self.partial: tuple[list[int], list[int]] = ([], [])
        self.valid_probability = 1.0
        self.ready_probability = 1.0
        self.current: tuple[int, int, bool] | None = None
        self.cycle = 0

    def idle(self) -> None:
        d = self.dut
        d.s_valid.value = 0
        d.s_re.value = 0
        d.s_im.value = 0
        d.inverse.value = 0
        d.m_ready.value = 0
        self.current = None

    async def reset(self) -> None:
        self.idle()
        await self.domain.reset()
        self.source.clear()
        self.expected.clear()
        self.partial = ([], [])

    def queue(self, frame: Frame) -> None:
        for n in range(N):
            self.source.append((frame.re[n], frame.im[n], frame.inverse))
        re, im, ovf = fft_model(frame.re, frame.im, frame.inverse)
        for k in range(N):
            self.expected.append((re[k], im[k], k == N - 1, ovf))

    async def step(self) -> None:
        d = self.dut
        if self.current is None and self.source and self.rng.boolean(self.valid_probability):
            self.current = self.source[0]
        d.s_valid.value = int(self.current is not None)
        if self.current is not None:
            d.s_re.value, d.s_im.value, inv = self.current
            d.inverse.value = int(inv)
        ready = self.rng.boolean(self.ready_probability)
        d.m_ready.value = int(ready)

        await Timer(CLK_PERIOD_NS / 2, units="ns")
        s_ready = int(d.s_ready.value)
        m_valid = int(d.m_valid.value)
        out = (to_signed(int(d.m_re.value), DATA_WIDTH), to_signed(int(d.m_im.value), DATA_WIDTH),
               bool(int(d.m_last.value)), bool(int(d.m_overflow.value)))

        await RisingEdge(d.clk)
        self.cycle += 1
        if m_valid and ready:
            if not self.expected:
                raise AssertionError(f"cycle {self.cycle}: output with no frame")
            want = self.expected.popleft()
            bin_ = len(self.partial[0])
            for name, got, exp in zip(("re", "im", "m_last", "m_overflow"), out, want):
                assert_eq(int(got), int(exp), f"frame {len(self.results)} bin {bin_}: {name}")
            self.partial[0].append(out[0])
            self.partial[1].append(out[1])
            if out[2]:
                self.results.append((self.partial[0], self.partial[1], out[3]))
                self.partial = ([], [])
        if self.current is not None and s_ready:
            self.source.popleft()
            self.current = None

    async def run(self, frames: list[Frame], limit: int = 2000000):
        start = len(self.results)
        for f in frames:
            self.queue(f)
        begin = self.cycle
        while self.source or self.expected or self.current is not None:
            await self.step()
            if self.cycle - begin > limit:
                raise AssertionError("frames did not complete")
        return self.results[start:]


async def setup(dut, name: str) -> Harness:
    dut._log.info("fft: N_LOG2=%d (N=%d) DATA_WIDTH=%d, %s", N_LOG2, N, DATA_WIDTH, describe())
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    h = Harness(dut, domain, RandomStream(name))
    await h.reset()
    return h


def random_frame(rng: RandomStream, inverse: bool = False, scale: float = 1.0) -> Frame:
    lim = int(D_MAX * scale)
    return Frame([rng.between(-lim, lim) for _ in range(N)],
                 [rng.between(-lim, lim) for _ in range(N)], inverse)


def numpy_reference(frame: Frame) -> np.ndarray:
    x = np.array(frame.re, dtype=float) + 1j * np.array(frame.im, dtype=float)
    return (np.fft.ifft(x) if frame.inverse else np.fft.fft(x) / N)


def deviation(result, frame: Frame) -> float:
    got = np.array(result[0], dtype=float) + 1j * np.array(result[1], dtype=float)
    ref = numpy_reference(frame)
    return float(max(np.max(np.abs(got.real - ref.real)), np.max(np.abs(got.imag - ref.imag))))


# Each stage adds at most one LSB of rounding (product and halving), and the
# halving of later stages divides earlier errors down; the twiddles add a
# little more. A bound of N_LOG2 / 2 + 2 LSB holds with margin.
NUMPY_BOUND = N_LOG2 / 2 + 2


def isolate_clip(c: int) -> Frame:
    """A frame in which butterfly output c (0 x[i0].re, 1 x[i0].im, 2 x[i1].re,
    3 x[i1].im) saturates once and no other output does.

    Random frames never saturate - their samples average out - so the frame
    is built. Saturation needs a 45-degree twiddle, first used in stage 2,
    where butterfly 1 of group 0 combines a = bin 1 of the 4-point DFT of
    x[n*N/4] and b = bin 1 of the 4-point DFT of x[N/8 + n*N/4]. Feeding each
    subsequence a value times j**n makes a and b that value at full scale;
    with w at -45 degrees, a = (D, D) and b = (D, D) give t = (D*sqrt 2, 0)
    and (a + t) / 2 = (1.21 D, D/2): only the real part of x[i0] clips. The
    other three choices of a and b select the other outputs. Every other
    point of the frame is zero, so nothing else can saturate.
    """
    d = D_MAX
    a, b = {0: ((d, d), (d, d)), 1: ((d, d), (-d, d)),
            2: ((-d, -d), (d, d)), 3: ((d, -d), (-d, d))}[c]
    re, im = [0] * N, [0] * N
    for offset, (r, i) in ((0, a), (N // 8, b)):
        for n in range(4):
            re[offset + (N // 4) * n], im[offset + (N // 4) * n] = r, i
            r, i = -i, r                                    # times j
    return Frame(re, im)


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: ready to load, nothing to unload."""
    h = await setup(dut, "fft_reset")
    assert_eq(int(dut.s_ready.value), 1, "s_ready after reset")
    assert_eq(int(dut.m_valid.value), 0, "m_valid after reset")


@cocotb.test()
async def test_impulse_and_dc(dut) -> None:
    """Directed: an impulse gives a flat spectrum, DC gives bin 0 only."""
    h = await setup(dut, "fft_impulse")
    a = D_MAX // 2
    impulse = Frame([a] + [0] * (N - 1), [0] * N)
    dc = Frame([a] * N, [0] * N)
    (imp_re, imp_im, _), (dc_re, dc_im, _) = await h.run([impulse, dc])
    for k in range(N):
        assert_eq(int(abs(imp_re[k] - a / N) <= 1 and abs(imp_im[k]) <= 1), 1,
                  f"impulse bin {k}: {imp_re[k]}+{imp_im[k]}j")
    assert_eq(int(abs(dc_re[0] - a) <= 1), 1, f"DC bin 0: {dc_re[0]}")
    assert_eq(int(max(abs(v) for v in dc_re[1:] + dc_im) <= 1), 1, "DC leakage")


@cocotb.test()
async def test_every_bin(dut) -> None:
    """Directed: a complex tone at bin m lands in bin m, nowhere else."""
    h = await setup(dut, "fft_bins")
    a = D_MAX * 0.7
    frames = [Frame([round(a * math.cos(2 * math.pi * m * n / N)) for n in range(N)],
                    [round(a * math.sin(2 * math.pi * m * n / N)) for n in range(N)])
              for m in range(N)]
    results = await h.run(frames)
    for m, (re, im, _) in enumerate(results):
        mag = [math.hypot(r, i) for r, i in zip(re, im)]
        peak = max(range(N), key=lambda k: mag[k])
        assert_eq(peak, m, f"tone {m} peak bin")
        assert_eq(int(abs(mag[m] - a) <= N_LOG2 + 2), 1, f"tone {m} magnitude {mag[m]:.1f}")
        others = max(mag[k] for k in range(N) if k != m)
        assert_eq(int(others <= NUMPY_BOUND * 1.5), 1, f"tone {m} leakage {others:.1f}")


@cocotb.test()
async def test_inverse(dut) -> None:
    """Directed: the inverse of a single bin is a complex tone at full scale."""
    h = await setup(dut, "fft_inverse")
    a = D_MAX // 2
    for m in (0, 1, N // 2, N - 1):
        re = [0] * N
        re[m] = a
        (out_re, out_im, _), = await h.run([Frame(re, [0] * N, inverse=True)])
        for n in range(N):
            assert_eq(int(abs(out_re[n] - a / N * math.cos(2 * math.pi * m * n / N)) <= 1.5
                          and abs(out_im[n] - a / N * math.sin(2 * math.pi * m * n / N)) <= 1.5),
                      1, f"inverse of bin {m}, sample {n}")


@cocotb.test()
async def test_frame_timing(dut) -> None:
    """Directed: N load, (N/2) log2 N compute and N unload cycles."""
    h = await setup(dut, "fft_timing")
    begin = h.cycle
    await h.run([random_frame(h.rng)])
    assert_eq(h.cycle - begin, 2 * N + (N // 2) * N_LOG2, "cycles for one frame")


@cocotb.test()
async def test_overflow_flag(dut) -> None:
    """Directed: m_overflow reports a saturation in any one of the four
    butterfly outputs alone, and stays low on a quiet frame."""
    h = await setup(dut, "fft_overflow")
    names = ["x[i0].re", "x[i0].im", "x[i1].re", "x[i1].im"]
    frames = [isolate_clip(c) for c in range(4)]
    for c, f in enumerate(frames):
        clips = fft_model_clips(f.re, f.im, f.inverse)[2]
        assert_eq(int(clips[c] > 0 and sum(clips) == clips[c]), 1,
                  f"constructed frame saturates only {names[c]}: {clips}")
    quiet = random_frame(h.rng, scale=0.25)
    results = await h.run(frames + [quiet])
    for c in range(4):
        assert_eq(int(results[c][2]), 1, f"m_overflow when only {names[c]} saturates")
    assert_eq(int(results[4][2]), 0, "m_overflow, quiet frame")


@cocotb.test()
async def test_reset_mid_frame(dut) -> None:
    """Directed: a reset mid-load and mid-unload starts a clean frame."""
    h = await setup(dut, "fft_midreset")
    h.queue(random_frame(h.rng))
    for _ in range(N // 2):
        await h.step()
    await h.reset()
    h.queue(random_frame(h.rng))
    h.ready_probability = 0.0
    for _ in range(N + (N // 2) * N_LOG2 + 5):
        await h.step()
    await h.reset()
    h.ready_probability = 1.0
    await h.run([random_frame(h.rng)])


# ---------------------------------------------------------------------------
# Randomised and independent
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_frames(dut) -> None:
    """Randomised: forward and inverse frames, gaps and back-pressure."""
    h = await setup(dut, "fft_random")
    for valid_p, ready_p in [(1.0, 1.0), (0.6, 0.8), (0.8, 0.3)]:
        h.valid_probability, h.ready_probability = valid_p, ready_p
        frames = [random_frame(h.rng, inverse=h.rng.boolean(), scale=h.rng.choice([0.3, 0.6]))
                  for _ in range(6)]
        await h.run(frames)


@cocotb.test()
async def test_against_numpy(dut) -> None:
    """Independent: every frame within a rounding bound of numpy.fft."""
    h = await setup(dut, "fft_numpy")
    frames = [random_frame(h.rng, inverse=(i % 2 == 1), scale=0.4) for i in range(12)]
    results = await h.run(frames)
    worst = max(deviation(r, f) for r, f in zip(results, frames))
    dut._log.info("worst deviation from numpy: %.2f LSB (bound %.1f)", worst, NUMPY_BOUND)
    assert_eq(int(worst <= NUMPY_BOUND), 1, f"deviation {worst:.2f} LSB")
