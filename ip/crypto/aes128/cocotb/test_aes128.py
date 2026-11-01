"""Cocotb regression for aes128.

Coverage
    directed   the reset state (no key: no block accepted), the FIPS-197
               appendix B and C.1 vectors and two NIST AESAVS known answers
               in both directions, the key-load and block cycle counts, a
               key load offered together with a block (the key wins), a key
               change between blocks, s_decrypt ignored when DECRYPT = 0,
               and a reset in the middle of a block
    randomised random keys, blocks and directions with source gaps and sink
               back-pressure against the model; every ciphertext decrypted
               back to its plaintext

The reference is aes_model.py, written from FIPS-197 with its own S-box
computed from the field arithmetic, so it shares nothing with the generated
ROMs. Keys and blocks interleave in one ordered source, so every block is
checked against the key in force when it was accepted. One coroutine runs
every cycle: drive after the edge, settle, sample, and resolve the edge.
"""
from __future__ import annotations

from collections import deque

import cocotb
from cocotb.triggers import RisingEdge, Timer

import aes_model
from socip import ClockDomain, RandomStream, assert_eq, describe, get_param

DECRYPT = get_param("DECRYPT", 1)

CLK_PERIOD_NS = 10.0
BLOCK_CYCLES = 11
KEY_CYCLES = 11 if DECRYPT else 1


class Harness:
    def __init__(self, dut, domain: ClockDomain, rng: RandomStream) -> None:
        self.dut = dut
        self.domain = domain
        self.rng = rng
        self.source: deque[tuple] = deque()       # ("key", k) or ("block", data, decrypt)
        self.expected: deque[int] = deque()
        self.outputs: list[int] = []
        self.key: int | None = None
        self.valid_probability = 1.0
        self.ready_probability = 1.0
        self.current: tuple | None = None
        self.cycle = 0
        self.key_cycles: list[int] = []
        self.block_cycles: list[int] = []
        self.output_cycles: list[int] = []

    def idle(self) -> None:
        d = self.dut
        d.key_valid.value = 0
        d.key.value = 0
        d.s_valid.value = 0
        d.s_data.value = 0
        d.s_decrypt.value = 0
        d.m_ready.value = 0
        self.current = None

    async def reset(self) -> None:
        self.idle()
        await self.domain.reset()
        self.source.clear()
        self.expected.clear()
        self.key = None

    def load_key(self, key: int) -> None:
        self.source.append(("key", key))

    def block(self, data: int, decrypt: bool = False) -> None:
        self.source.append(("block", data, decrypt))

    def model(self, data: int, decrypt: bool) -> int:
        assert self.key is not None
        if decrypt and DECRYPT:
            return aes_model.decrypt(self.key, data)
        return aes_model.encrypt(self.key, data)

    async def step(self, extra_key: int | None = None) -> None:
        d = self.dut
        if self.current is None and self.source and self.rng.boolean(self.valid_probability):
            self.current = self.source[0]
        op = self.current
        key_op = op is not None and op[0] == "key"
        block_op = op is not None and op[0] == "block"
        d.key_valid.value = int(key_op or extra_key is not None)
        d.key.value = op[1] if key_op else (extra_key or 0)
        d.s_valid.value = int(block_op)
        d.s_data.value = op[1] if block_op else 0
        d.s_decrypt.value = int(op[2]) if block_op else 0
        ready = self.rng.boolean(self.ready_probability)
        d.m_ready.value = int(ready)

        await Timer(CLK_PERIOD_NS / 2, units="ns")
        key_ready = int(d.key_ready.value)
        s_ready = int(d.s_ready.value)
        m_valid = int(d.m_valid.value)
        out = int(d.m_data.value)

        await RisingEdge(d.clk)
        self.cycle += 1
        if m_valid and ready:
            if not self.expected:
                raise AssertionError(f"cycle {self.cycle}: output with no block")
            want = self.expected.popleft()
            if out != want:
                raise AssertionError(f"cycle {self.cycle}: block {len(self.outputs)} is "
                                     f"{out:032x}, expected {want:032x}")
            self.outputs.append(out)
            self.output_cycles.append(self.cycle)
        if (key_op or extra_key is not None) and key_ready:
            self.key = op[1] if key_op else extra_key
            self.key_cycles.append(self.cycle)
            if key_op:
                self.source.popleft()
                self.current = None
        if block_op and s_ready:
            self.expected.append(self.model(op[1], op[2]))
            self.block_cycles.append(self.cycle)
            self.source.popleft()
            self.current = None

    async def drain(self, limit: int = 500000) -> list[int]:
        start = len(self.outputs)
        begin = self.cycle
        while self.source or self.expected or self.current is not None:
            await self.step()
            if self.cycle - begin > limit:
                raise AssertionError("blocks did not drain")
        return self.outputs[start:]


async def setup(dut, name: str) -> Harness:
    dut._log.info("aes128: DECRYPT=%d, %s", DECRYPT, describe())
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    h = Harness(dut, domain, RandomStream(name))
    await h.reset()
    return h


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: after reset no key is loaded, so no block is accepted."""
    h = await setup(dut, "aes_reset")
    assert_eq(int(dut.m_valid.value), 0, "m_valid after reset")
    assert_eq(int(dut.key_ready.value), 1, "key_ready after reset")
    dut.s_valid.value = 1
    for _ in range(30):
        await Timer(CLK_PERIOD_NS / 2, units="ns")
        assert_eq(int(dut.s_ready.value), 0, "s_ready with no key")
        await RisingEdge(dut.clk)
    h.idle()


@cocotb.test()
async def test_fips_vectors(dut) -> None:
    """Directed: FIPS-197 appendix B and C.1 and AESAVS answers, both directions."""
    h = await setup(dut, "aes_fips")
    assert_eq(aes_model.expand_key(aes_model.VECTORS[0][0])[10], aes_model.LAST_ROUND_KEY_B,
              "model key schedule, FIPS-197 appendix A.1")
    for key, plain, cipher in aes_model.VECTORS:
        h.load_key(key)
        h.block(plain)
        h.block(cipher, decrypt=True)
        out = await h.drain()
        assert_eq(out[0], cipher, f"encryption under key {key:032x}")
        if DECRYPT:
            assert_eq(out[1], plain, f"decryption under key {key:032x}")


@cocotb.test()
async def test_cycle_counts(dut) -> None:
    """Directed: a key loads in 11 cycles (1 without DECRYPT); blocks take 11 each."""
    h = await setup(dut, "aes_cycles")
    h.load_key(h.rng.uint(128))
    n = 8
    for i in range(n):
        h.block(h.rng.uint(128), decrypt=bool(i % 2))
    await h.drain()
    assert_eq(h.block_cycles[0] - h.key_cycles[0], KEY_CYCLES, "key load to first block")
    for i in range(1, n):
        assert_eq(h.block_cycles[i] - h.block_cycles[i - 1], BLOCK_CYCLES, f"block {i} spacing")
    for i in range(n):
        assert_eq(h.output_cycles[i] - h.block_cycles[i], BLOCK_CYCLES, f"block {i} latency")


@cocotb.test()
async def test_key_wins(dut) -> None:
    """Directed: a key offered with a block loads first; the block uses the new key."""
    h = await setup(dut, "aes_key_wins")
    h.load_key(h.rng.uint(128))
    await h.drain()
    for _ in range(4):
        for _ in range(KEY_CYCLES):              # let the key schedule finish
            await h.step()
        h.block(h.rng.uint(128), decrypt=h.rng.boolean())
        new_key = h.rng.uint(128)
        await h.step(extra_key=new_key)
        assert_eq(h.key, new_key, "the key was taken")
        assert_eq(len(h.source), 1, "the block was not taken with the key")
        await h.drain()


@cocotb.test()
async def test_key_change(dut) -> None:
    """Directed: a new key between blocks applies to the blocks after it."""
    h = await setup(dut, "aes_key_change")
    for _ in range(10):
        h.load_key(h.rng.corner_uint(128))
        for _ in range(h.rng.between(1, 3)):
            h.block(h.rng.corner_uint(128), decrypt=h.rng.boolean())
    await h.drain()


@cocotb.test()
async def test_decrypt_flag(dut) -> None:
    """Directed: s_decrypt selects the inverse cipher; ignored when DECRYPT = 0."""
    h = await setup(dut, "aes_decrypt_flag")
    key, plain, cipher = aes_model.VECTORS[1]
    h.load_key(key)
    h.block(cipher, decrypt=True)
    out = await h.drain()
    want = plain if DECRYPT else aes_model.encrypt(key, cipher)
    assert_eq(out[0], want, "result with s_decrypt high")


@cocotb.test()
async def test_reset_mid_block(dut) -> None:
    """Directed: a reset abandons a block and forgets the key."""
    h = await setup(dut, "aes_midreset")
    h.load_key(h.rng.uint(128))
    h.block(h.rng.uint(128))
    for _ in range(KEY_CYCLES + 5):
        await h.step()
    await h.reset()
    assert_eq(int(dut.m_valid.value), 0, "m_valid after reset")
    assert_eq(int(dut.s_ready.value), 0, "s_ready after reset: the key is gone")
    key, plain, cipher = aes_model.VECTORS[0]
    h.load_key(key)
    h.block(plain)
    out = await h.drain()
    assert_eq(out[0], cipher, "first block after reset")


# ---------------------------------------------------------------------------
# Randomised
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_blocks(dut) -> None:
    """Randomised: keys, blocks and directions under gaps and back-pressure; round trips."""
    h = await setup(dut, "aes_random")
    for valid_p, ready_p in [(1.0, 1.0), (0.6, 0.8), (0.9, 0.2), (0.4, 0.5)]:
        h.valid_probability, h.ready_probability = valid_p, ready_p
        for _ in range(6):
            key = h.rng.uint(128)
            plains = [h.rng.corner_uint(128) for _ in range(h.rng.between(1, 8))]
            h.load_key(key)
            for p in plains:
                h.block(p)
            ciphers = await h.drain()
            if DECRYPT:
                for c in ciphers:
                    h.block(c, decrypt=True)
                back = await h.drain()
                assert_eq(int(back == plains), 1, "decryption returns the plaintexts")
    h.valid_probability = h.ready_probability = 1.0
