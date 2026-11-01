"""Cocotb regression for sha256.

Coverage
    directed   the reset state, the FIPS 180-4 / NIST example messages (the
               empty one, "abc", the 448- and 896-bit two-block ones), every
               message length from 0 to 140 bytes - each padding case,
               including the spill into an extra block at 56..63 bytes into
               a block - the exact cycle count of a long message, a digest
               left waiting while the next messages stream in, s_nbytes
               above 4 and junk in the ignored bytes, and a reset in the
               middle of a message
    randomised random messages, random endings (a short last word, or a
               full one followed by an empty s_last word), source gaps and
               sink back-pressure

The reference is Python's hashlib, which shares no code or structure with
the design. A message is sent as big-endian words; its last word carries the
remaining 0..4 bytes. One coroutine runs every cycle: drive after the edge,
settle, sample, and resolve the handshakes the next edge will see.
"""
from __future__ import annotations

import hashlib
from collections import deque

import cocotb
from cocotb.triggers import RisingEdge, Timer

from socip import ClockDomain, RandomStream, assert_eq, describe

CLK_PERIOD_NS = 10.0
CYCLES_PER_BLOCK = 65


def to_words(msg: bytes, rng: RandomStream | None = None,
             empty_last: bool = False) -> list[tuple[int, int, int]]:
    """(data, last, nbytes) words for msg; junk fills the unused bytes."""
    words = []
    full, rest = divmod(len(msg), 4)
    if rest == 0 and full > 0 and not empty_last:
        full, rest = full - 1, 4
    for i in range(full):
        nb = rng.between(0, 7) if rng else 4             # ignored on these words
        words.append((int.from_bytes(msg[4 * i:4 * i + 4], "big"), 0, nb))
    tail = msg[4 * full:]
    junk = rng.uint(32) if rng else 0
    data = int.from_bytes(tail + bytes(4 - len(tail)), "big")
    if len(tail) < 4:
        data |= junk & ((1 << (8 * (4 - len(tail)))) - 1)
    nb = len(tail)
    if nb == 4 and rng and rng.boolean(0.5):
        nb = rng.between(5, 7)                           # counts as 4
    words.append((data, 1, nb))
    return words


class Harness:
    def __init__(self, dut, domain: ClockDomain, rng: RandomStream) -> None:
        self.dut = dut
        self.domain = domain
        self.rng = rng
        self.source: deque[tuple[int, int, int]] = deque()
        self.expected: deque[bytes] = deque()
        self.digests: list[bytes] = []
        self.valid_probability = 1.0
        self.ready_probability = 1.0
        self.current: tuple[int, int, int] | None = None
        self.cycle = 0
        self.accept_cycles: list[int] = []
        self.digest_cycles: list[int] = []

    def idle(self) -> None:
        d = self.dut
        d.s_valid.value = 0
        d.s_data.value = 0
        d.s_last.value = 0
        d.s_nbytes.value = 0
        d.m_ready.value = 0
        self.current = None

    async def reset(self) -> None:
        self.idle()
        await self.domain.reset()
        self.source.clear()
        self.expected.clear()

    def send(self, msg: bytes, junk: bool = False, empty_last: bool = False) -> None:
        self.source.extend(to_words(msg, self.rng if junk else None, empty_last))
        self.expected.append(hashlib.sha256(msg).digest())

    async def step(self) -> None:
        d = self.dut
        if self.current is None and self.source and self.rng.boolean(self.valid_probability):
            self.current = self.source[0]
        word = self.current or (0, 0, 0)
        d.s_valid.value = int(self.current is not None)
        d.s_data.value, d.s_last.value, d.s_nbytes.value = word
        ready = self.rng.boolean(self.ready_probability)
        d.m_ready.value = int(ready)

        await Timer(CLK_PERIOD_NS / 2, units="ns")
        s_ready = int(d.s_ready.value)
        m_valid = int(d.m_valid.value)
        digest = int(d.m_digest.value).to_bytes(32, "big")

        await RisingEdge(d.clk)
        self.cycle += 1
        if m_valid and ready:
            if not self.expected:
                raise AssertionError(f"cycle {self.cycle}: digest with no message")
            want = self.expected.popleft()
            if digest != want:
                raise AssertionError(f"cycle {self.cycle}: digest {len(self.digests)} is "
                                     f"{digest.hex()}, expected {want.hex()}")
            self.digests.append(digest)
            self.digest_cycles.append(self.cycle)
        if self.current is not None and s_ready:
            self.accept_cycles.append(self.cycle)
            self.source.popleft()
            self.current = None

    async def drain(self, limit: int = 2_000_000) -> None:
        begin = self.cycle
        while self.source or self.expected or self.current is not None:
            await self.step()
            if self.cycle - begin > limit:
                raise AssertionError("messages did not drain")


async def setup(dut, name: str) -> Harness:
    dut._log.info("sha256: %s", describe())
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    h = Harness(dut, domain, RandomStream(name))
    await h.reset()
    return h


def rand_bytes(rng: RandomStream, n: int) -> bytes:
    return bytes(rng.uint(8) for _ in range(n))


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: no digest, input ready, after reset."""
    await setup(dut, "sha_reset")
    assert_eq(int(dut.m_valid.value), 0, "m_valid after reset")
    assert_eq(int(dut.s_ready.value), 1, "s_ready after reset")


@cocotb.test()
async def test_nist_examples(dut) -> None:
    """Directed: the FIPS 180-4 example messages, digests written out in full."""
    h = await setup(dut, "sha_nist")
    vectors = [
        (b"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        (b"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        (b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
        (b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmno"
         b"ijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu",
         "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"),
    ]
    for msg, digest in vectors:
        assert_eq(int(hashlib.sha256(msg).hexdigest() == digest), 1, f"reference for {msg[:8]!r}")
        h.send(msg)
    await h.drain()


@cocotb.test()
async def test_every_length(dut) -> None:
    """Directed: lengths 0..140 bytes back to back, every padding case."""
    h = await setup(dut, "sha_lengths")
    for n in range(141):
        h.send(rand_bytes(h.rng, n))
    await h.drain()


@cocotb.test()
async def test_cycle_count(dut) -> None:
    """Directed: a message of n blocks fed back to back takes 65 * n cycles."""
    h = await setup(dut, "sha_cycles")
    for blocks in (1, 2, 7):
        length = 64 * blocks - 9                  # the padding exactly fills the last block
        h.send(rand_bytes(h.rng, length))
        first = len(h.accept_cycles)
        await h.drain()
        took = h.digest_cycles[-1] - h.accept_cycles[first]
        assert_eq(took, CYCLES_PER_BLOCK * blocks, f"cycles for {blocks} block(s)")
    # One byte more spills the padding into one more block.
    h.send(rand_bytes(h.rng, 64 - 8))
    first = len(h.accept_cycles)
    await h.drain()
    assert_eq(h.digest_cycles[-1] - h.accept_cycles[first], 2 * CYCLES_PER_BLOCK,
              "cycles for 56 bytes")


@cocotb.test()
async def test_digest_waits(dut) -> None:
    """Directed: a digest left waiting holds, and the next message stalls only at its end."""
    h = await setup(dut, "sha_wait")
    h.ready_probability = 0.0
    for n in (3, 70, 130):
        h.send(rand_bytes(h.rng, n))
    for _ in range(600):
        await h.step()
    assert_eq(len(h.digests), 0, "no digest taken while m_ready is low")
    h.ready_probability = 1.0
    await h.drain()


@cocotb.test()
async def test_junk_and_nbytes(dut) -> None:
    """Directed: ignored bytes and s_nbytes on non-last words do not matter; above 4 counts as 4."""
    h = await setup(dut, "sha_junk")
    for n in range(0, 72):
        h.send(rand_bytes(h.rng, n), junk=True)
    for n in (4, 8, 60, 64):
        h.send(rand_bytes(h.rng, n), junk=True, empty_last=True)
    await h.drain()


@cocotb.test()
async def test_reset_mid_message(dut) -> None:
    """Directed: a reset abandons a message; the next one hashes from scratch."""
    h = await setup(dut, "sha_midreset")
    h.send(rand_bytes(h.rng, 100))
    for _ in range(40):
        await h.step()
    await h.reset()
    assert_eq(int(dut.m_valid.value), 0, "m_valid after reset")
    h.send(b"abc")
    await h.drain()


# ---------------------------------------------------------------------------
# Randomised
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_messages(dut) -> None:
    """Randomised: random messages and endings under gaps and back-pressure."""
    h = await setup(dut, "sha_random")
    for valid_p, ready_p in [(1.0, 1.0), (0.6, 0.8), (0.9, 0.2), (0.4, 0.5)]:
        h.valid_probability, h.ready_probability = valid_p, ready_p
        for _ in range(12):
            n = h.rng.between(0, 400)
            h.send(rand_bytes(h.rng, n), junk=h.rng.boolean(0.5),
                   empty_last=(n % 4 == 0 and h.rng.boolean(0.5)))
        await h.drain()
    h.valid_probability = h.ready_probability = 1.0
