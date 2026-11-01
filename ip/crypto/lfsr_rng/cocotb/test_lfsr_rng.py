"""Cocotb regression for lfsr_rng.

Coverage
    directed   the reset state and the first draw from SEED, one draw per
               cycle, a draw held under a stall, a seed load and the draws it
               produces, the zero seed, a seed load on the same edge as a
               consumed draw, and a reset in the middle of a sequence
    randomised long runs under random back-pressure and random reseeding,
               draw for draw against the reference model
    property   Berlekamp-Massey on the design's own output recovers a
               feedback polynomial of degree WIDTH, and that polynomial is
               primitive - the period is 2**WIDTH - 1 - checked by factoring
               2**WIDTH - 1, not by trusting the tap table

The reference model is the recurrence in the RTL header with the XAPP052 tap
table copied here; the property test is what makes the copy trustworthy,
since a wrong tap gives a polynomial that is not primitive. One coroutine
runs every cycle: drive after the edge, settle, sample, and resolve the edge.
"""
from __future__ import annotations

import math
import random

import cocotb
from cocotb.triggers import RisingEdge, Timer

from socip import ClockDomain, RandomStream, assert_eq, describe, get_param

WIDTH = get_param("WIDTH", 32)
STEPS = get_param("STEPS", 8)
SEED = get_param("SEED", 1)

CLK_PERIOD_NS = 10.0
MASK = (1 << WIDTH) - 1

# Xilinx XAPP052: taps k of b[t] = XOR b[t-k].
XAPP052 = {
    2: (2, 1), 3: (3, 2), 4: (4, 3), 5: (5, 3), 6: (6, 5), 7: (7, 6), 8: (8, 6, 5, 4),
    9: (9, 5), 10: (10, 7), 11: (11, 9), 12: (12, 6, 4, 1), 13: (13, 4, 3, 1),
    14: (14, 5, 3, 1), 15: (15, 14), 16: (16, 15, 13, 4), 17: (17, 14), 18: (18, 11),
    19: (19, 6, 2, 1), 20: (20, 17), 21: (21, 19), 22: (22, 21), 23: (23, 18),
    24: (24, 23, 22, 17), 25: (25, 22), 26: (26, 6, 2, 1), 27: (27, 5, 2, 1), 28: (28, 25),
    29: (29, 27), 30: (30, 6, 4, 1), 31: (31, 28), 32: (32, 22, 2, 1), 33: (33, 20),
    34: (34, 27, 2, 1), 35: (35, 33), 36: (36, 25), 37: (37, 5, 4, 3, 2, 1),
    38: (38, 6, 5, 1), 39: (39, 35), 40: (40, 38, 21, 19), 41: (41, 38),
    42: (42, 41, 20, 19), 43: (43, 42, 38, 37), 44: (44, 43, 18, 17), 45: (45, 44, 42, 41),
    46: (46, 45, 26, 25), 47: (47, 42), 48: (48, 47, 21, 20), 49: (49, 40),
    50: (50, 49, 24, 23), 51: (51, 50, 36, 35), 52: (52, 49), 53: (53, 52, 38, 37),
    54: (54, 53, 18, 17), 55: (55, 31), 56: (56, 55, 35, 34), 57: (57, 50), 58: (58, 39),
    59: (59, 58, 38, 37), 60: (60, 59), 61: (61, 60, 46, 45), 62: (62, 61, 6, 5),
    63: (63, 62), 64: (64, 63, 61, 60),
}


class Model:
    """The state holds b[t-1] in bit 0; a step shifts the new bit in there."""

    def __init__(self) -> None:
        self.taps = sum(1 << (k - 1) for k in XAPP052[WIDTH])
        self.state = 0

    def draw(self, state: int) -> int:
        for _ in range(STEPS):
            state = ((state << 1) & MASK) | (bin(state & self.taps).count("1") & 1)
        return state

    def seed(self, value: int) -> None:
        value &= MASK
        self.state = self.draw(value if value else 1)

    def advance(self) -> None:
        self.state = self.draw(self.state)

    @property
    def data(self) -> int:
        return self.state & ((1 << STEPS) - 1)


class Harness:
    def __init__(self, dut, domain: ClockDomain, rng: RandomStream) -> None:
        self.dut = dut
        self.domain = domain
        self.rng = rng
        self.model = Model()
        self.ready_probability = 1.0
        self.seed_probability = 0.0
        self.draws: list[int] = []
        self.cycle = 0

    def idle(self) -> None:
        self.dut.seed_load.value = 0
        self.dut.seed.value = 0
        self.dut.m_ready.value = 0

    async def reset(self) -> None:
        self.idle()
        await self.domain.reset()
        self.model.seed(SEED)

    async def step(self, seed: int | None = None, ready: bool | None = None) -> None:
        d = self.dut
        if seed is None and self.rng.boolean(self.seed_probability):
            seed = self.rng.corner_uint(WIDTH)
        if ready is None:
            ready = self.rng.boolean(self.ready_probability)
        d.seed_load.value = int(seed is not None)
        d.seed.value = seed if seed is not None else 0
        d.m_ready.value = int(ready)

        await Timer(CLK_PERIOD_NS / 2, units="ns")
        valid = int(d.m_valid.value)
        data = int(d.m_data.value)
        assert_eq(valid, 1, f"cycle {self.cycle}: m_valid")
        assert_eq(data, self.model.data, f"cycle {self.cycle}: draw {len(self.draws)}")

        await RisingEdge(d.clk)
        self.cycle += 1
        if ready:
            self.draws.append(data)
        if seed is not None:
            self.model.seed(seed)
        elif ready:
            self.model.advance()

    async def take(self, n: int) -> list[int]:
        start = len(self.draws)
        while len(self.draws) - start < n:
            await self.step()
        return self.draws[start:start + n]


async def setup(dut, name: str) -> Harness:
    dut._log.info("lfsr_rng: WIDTH=%d STEPS=%d SEED=%d, %s", WIDTH, STEPS, SEED, describe())
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    h = Harness(dut, domain, RandomStream(name))
    await h.reset()                  # returns after the first edge: m_valid is high
    return h


def bits_of(draws: list[int]) -> list[int]:
    """The sequence in generation order: each draw holds its oldest bit at the top."""
    return [(d >> (STEPS - 1 - i)) & 1 for d in draws for i in range(STEPS)]


# ---------------------------------------------------------------------------
# GF(2) helpers for the property test
# ---------------------------------------------------------------------------

def berlekamp_massey(s: list[int]) -> tuple[int, int]:
    """Shortest LFSR generating s: (length L, connection polynomial as an int)."""
    c, b = 1, 1
    length, m = 0, 1
    for n in range(len(s)):
        d = s[n]
        for i in range(1, length + 1):
            d ^= ((c >> i) & 1) & s[n - i]
        if d == 0:
            m += 1
        elif 2 * length <= n:
            t = c
            c ^= b << m
            length, b, m = n + 1 - length, t, 1
        else:
            c ^= b << m
            m += 1
    return length, c


def gf2_mulmod(a: int, b: int, p: int, n: int) -> int:
    r = 0
    while b:
        if b & 1:
            r ^= a
        b >>= 1
        a <<= 1
        if (a >> n) & 1:
            a ^= p
    return r


def gf2_x_pow(e: int, p: int, n: int) -> int:
    r, base = 1, 2
    while e:
        if e & 1:
            r = gf2_mulmod(r, base, p, n)
        base = gf2_mulmod(base, base, p, n)
        e >>= 1
    return r


def is_prime(n: int) -> bool:
    if n < 2:
        return False
    small = (2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37)
    for q in small:
        if n % q == 0:
            return n == q
    d, s = n - 1, 0
    while d % 2 == 0:
        d //= 2
        s += 1
    for a in small:                       # deterministic below 3.3e24
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(s - 1):
            x = x * x % n
            if x == n - 1:
                break
        else:
            return False
    return True


def prime_factors(n: int) -> set[int]:
    found: set[int] = set()
    for q in range(2, 1 << 12):
        while n % q == 0:
            found.add(q)
            n //= q
    pending = [n] if n > 1 else []
    rng = random.Random(1)
    while pending:
        m = pending.pop()
        if is_prime(m):
            found.add(m)
            continue
        while True:                       # Pollard rho
            x = y = rng.randrange(2, m)
            c, g = rng.randrange(1, m), 1
            while g == 1:
                x = (x * x + c) % m
                y = (y * y + c) % m
                y = (y * y + c) % m
                g = math.gcd(abs(x - y), m)
            if g != m:
                pending += [g, m // g]
                break
    return found


def is_primitive(p: int, n: int) -> bool:
    order = (1 << n) - 1
    return gf2_x_pow(order, p, n) == 1 and all(
        gf2_x_pow(order // q, p, n) != 1 for q in prime_factors(order))


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: m_valid rises after reset and the first draw comes from SEED."""
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    h = Harness(dut, domain, RandomStream("lfsr_reset"))
    h.idle()
    dut.rst_n.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, units="ns")
    h.model.seed(SEED)
    assert_eq(int(dut.m_valid.value), 0, "m_valid in reset")
    assert_eq(int(dut.m_data.value), h.model.data, "first draw from SEED, in reset")
    dut.rst_n.value = 1
    await Timer(1, units="ns")
    assert_eq(int(dut.m_valid.value), 0, "m_valid before the first edge")
    await RisingEdge(dut.clk)
    await h.take(4 * WIDTH)


@cocotb.test()
async def test_one_draw_per_cycle(dut) -> None:
    """Directed: with m_ready held high a new draw is ready every cycle."""
    h = await setup(dut, "lfsr_rate")
    begin = h.cycle
    await h.take(500)
    assert_eq(h.cycle - begin, 500, "cycles for 500 draws")


@cocotb.test()
async def test_held_under_stall(dut) -> None:
    """Directed: without m_ready the draw is held, however long."""
    h = await setup(dut, "lfsr_hold")
    for _ in range(20):
        await h.step(ready=False)
    await h.take(10)


@cocotb.test()
async def test_seed_load(dut) -> None:
    """Directed: a seed load restarts the sequence, the zero seed included."""
    h = await setup(dut, "lfsr_seed")
    seeds = [0, 1, MASK, 1 << (WIDTH - 1), 0x5A5A5A5A5A5A5A5A & MASK]
    for value in seeds:
        await h.step(seed=value, ready=False)
        first = await h.take(2 * WIDTH)
        await h.step(seed=value, ready=False)
        again = await h.take(2 * WIDTH)
        assert_eq(int(first == again), 1, f"seed {value:#x} repeats its sequence")
    # The zero seed starts the sequence of seed 1.
    await h.step(seed=0, ready=False)
    zero = await h.take(2 * WIDTH)
    await h.step(seed=1, ready=False)
    one = await h.take(2 * WIDTH)
    assert_eq(int(zero == one), 1, "the zero seed is replaced by 1")


@cocotb.test()
async def test_seed_with_draw(dut) -> None:
    """Directed: a draw consumed on the seed-load edge is the last of the old sequence."""
    h = await setup(dut, "lfsr_seed_edge")
    for _ in range(20):
        await h.take(h.rng.between(1, 2 * WIDTH))
        await h.step(seed=h.rng.uint(WIDTH), ready=True)


@cocotb.test()
async def test_reset_mid_sequence(dut) -> None:
    """Directed: a reset returns the generator to SEED, whatever it was doing."""
    h = await setup(dut, "lfsr_midreset")
    await h.step(seed=h.rng.uint(WIDTH))
    await h.take(37)
    await h.reset()
    after = await h.take(3 * WIDTH)
    reference = Model()
    reference.seed(SEED)
    want = []
    for _ in range(3 * WIDTH):
        want.append(reference.data)
        reference.advance()
    assert_eq(int(after == want), 1, "sequence after reset")


# ---------------------------------------------------------------------------
# Randomised and property
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_run(dut) -> None:
    """Randomised: back-pressure and reseeding, draw for draw against the model."""
    h = await setup(dut, "lfsr_random")
    for ready_p, seed_p in [(1.0, 0.0), (0.5, 0.0), (0.7, 0.02), (0.3, 0.1)]:
        h.ready_probability, h.seed_probability = ready_p, seed_p
        for _ in range(1500):
            await h.step()
    h.ready_probability, h.seed_probability = 1.0, 0.0


@cocotb.test()
async def test_primitive_polynomial(dut) -> None:
    """Property: the output has linear complexity WIDTH and a primitive polynomial."""
    h = await setup(dut, "lfsr_bm")
    for value in (1, h.rng.uint(WIDTH)):
        await h.step(seed=value, ready=False)
        n_draws = -(-4 * WIDTH // STEPS)
        stream = bits_of(await h.take(n_draws))
        length, poly = berlekamp_massey(stream)
        assert_eq(length, WIDTH, f"linear complexity from seed {value:#x}")
        # c(x) = 1 + sum c_k x^k; it is primitive exactly when its
        # reciprocal, the characteristic polynomial, is.
        assert_eq(poly.bit_length() - 1, WIDTH, "connection polynomial degree")
        assert_eq(int(is_primitive(poly, WIDTH)), 1,
                  f"polynomial {poly:#x} is primitive: period 2**{WIDTH} - 1")
        dut._log.info("recovered polynomial %#x, primitive, period 2**%d - 1", poly, WIDTH)
