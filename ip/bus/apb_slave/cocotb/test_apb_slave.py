"""Cocotb regression for apb_slave.

Coverage
    directed   the reset state, zero-wait writes and reads, wait states from a
               slow register block, PSLVERR, byte strobes, back-to-back
               transfers with no idle cycle, and a reset in the middle of a
               transfer
    randomised transfers, gaps, wait states, strobes, protection and errors
               all drawn at random against a register model
    regression the request is issued exactly once per transfer, including in
               the cycle the registered response completes it

The APB requester and the register block behind the bridge are both written
from the specifications - AMBA APB4 for the bus, the RTL header for the
register port - not from the RTL. One coroutine runs every cycle in a fixed
order: drive the APB signals after the edge, let them settle, read the
register request, drive the register response, let that settle, and read the
APB response. The values read are the ones the next edge will see.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import cocotb
from cocotb.triggers import RisingEdge, Timer

from socip import ClockDomain, RandomStream, assert_eq, describe, get_param

ADDR_WIDTH = get_param("ADDR_WIDTH", 12)
DATA_WIDTH = get_param("DATA_WIDTH", 32)
REGISTERED = get_param("REGISTERED", 1)

CLK_PERIOD_NS = 10.0
STRB_WIDTH = DATA_WIDTH // 8
ADDR_MASK = (1 << ADDR_WIDTH) - 1
DATA_MASK = (1 << DATA_WIDTH) - 1
STRB_MASK = (1 << STRB_WIDTH) - 1


@dataclass
class Transfer:
    write: bool
    addr: int
    data: int = 0
    strb: int = STRB_MASK
    prot: int = 0
    gap: int = 0          # idle cycles before the setup phase


@dataclass
class Completion:
    transfer: Transfer
    rdata: int
    error: bool


@dataclass
class RegisterBlock:
    """The register logic behind the bridge: word storage, errors, waits."""

    rng: RandomStream
    words: dict[int, int] = field(default_factory=dict)
    error_words: set[int] = field(default_factory=set)
    wait_probability: float = 0.0
    max_wait: int = 0
    waited: int = 0
    accepted: list[Transfer] = field(default_factory=list)

    def index(self, addr: int) -> int:
        return addr // STRB_WIDTH

    def read(self, addr: int) -> int:
        return self.words.get(self.index(addr), 0)

    def error(self, addr: int) -> bool:
        return self.index(addr) in self.error_words

    def ready(self) -> bool:
        """Decide reg_ready for a request that is waiting this cycle."""
        if self.waited < self.max_wait and self.rng.boolean(self.wait_probability):
            self.waited += 1
            return False
        self.waited = 0
        return True

    def accept(self, write: bool, addr: int, data: int, strb: int,
               prot: int) -> None:
        self.accepted.append(Transfer(write, addr, data, strb, prot))
        if write and not self.error(addr):
            old = self.read(addr)
            new = old
            for byte in range(STRB_WIDTH):
                if strb >> byte & 1:
                    lane = 0xFF << (8 * byte)
                    new = (new & ~lane) | (data & lane)
            self.words[self.index(addr)] = new & DATA_MASK


class Harness:
    """APB requester, register block and checker, stepped one cycle at a time."""

    def __init__(self, dut, domain: ClockDomain, regs: RegisterBlock) -> None:
        self.dut = dut
        self.domain = domain
        self.regs = regs
        self.cycle = 0
        self.accepted_at: int | None = None

    def idle_bus(self) -> None:
        self.dut.psel.value = 0
        self.dut.penable.value = 0
        self.dut.pwrite.value = 0
        self.dut.paddr.value = 0
        self.dut.pwdata.value = 0
        self.dut.pstrb.value = 0
        self.dut.pprot.value = 0

    def idle_regs(self) -> None:
        self.dut.reg_ready.value = 0
        self.dut.reg_rdata.value = 0
        self.dut.reg_error.value = 0

    async def reset(self) -> None:
        self.idle_bus()
        self.idle_regs()
        await self.domain.reset()
        self.accepted_at = None

    async def cycle_step(self, psel: int, penable: int, t: Transfer | None
                         ) -> tuple[bool, bool, int, bool]:
        """Drive one cycle; return (request taken, transfer done, prdata,
        pslverr) as the next edge will see them."""
        d = self.dut
        d.psel.value = psel
        d.penable.value = penable
        if t is not None:
            d.pwrite.value = int(t.write)
            d.paddr.value = t.addr
            d.pwdata.value = t.data if t.write else 0
            d.pstrb.value = t.strb if t.write else 0
            d.pprot.value = t.prot
        else:
            self.idle_bus()

        await Timer(CLK_PERIOD_NS / 4, units="ns")
        valid = int(d.reg_valid.value)
        write = int(d.reg_write.value)
        addr = int(d.reg_addr.value)

        if psel and penable and t is not None and valid:
            assert_eq(write, int(t.write), f"cycle {self.cycle}: reg_write")
            assert_eq(addr, t.addr, f"cycle {self.cycle}: reg_addr")
            assert_eq(int(d.reg_prot.value), t.prot, f"cycle {self.cycle}: reg_prot")
            assert_eq(int(d.reg_strb.value), t.strb if t.write else 0,
                      f"cycle {self.cycle}: reg_strb")
            if t.write:
                assert_eq(int(d.reg_wdata.value), t.data,
                          f"cycle {self.cycle}: reg_wdata")
        if valid and not (psel and penable):
            raise AssertionError(f"cycle {self.cycle}: reg_valid outside an "
                                 "access phase")

        ready = self.regs.ready() if valid else self.regs.rng.boolean()
        d.reg_ready.value = int(ready)
        d.reg_rdata.value = self.regs.read(addr) if not write else \
            self.regs.rng.uint(DATA_WIDTH)
        d.reg_error.value = int(self.regs.error(addr))

        await Timer(CLK_PERIOD_NS / 4, units="ns")
        pready = int(d.pready.value)
        prdata = int(d.prdata.value)
        pslverr = int(d.pslverr.value)
        taken = bool(valid and ready)
        expected_rdata = self.regs.read(addr)
        expected_error = self.regs.error(addr)

        await RisingEdge(d.clk)
        self.cycle += 1

        if taken:
            if self.accepted_at is not None:
                raise AssertionError(f"cycle {self.cycle}: second request for "
                                     "one transfer")
            self.accepted_at = self.cycle
            self.regs.accept(bool(write), addr, int(d.reg_wdata.value),
                             int(d.reg_strb.value), int(d.reg_prot.value))
            self.pending = (expected_rdata if not write else 0, expected_error)

        done = bool(psel and penable and pready)
        if REGISTERED and pready and not (psel and penable):
            # Direct mode forwards reg_ready, which is free outside a transfer.
            raise AssertionError(f"cycle {self.cycle}: PREADY outside an access "
                                 "phase")
        return taken, done, prdata, bool(pslverr)

    async def transfer(self, t: Transfer) -> Completion:
        for _ in range(t.gap):
            await self.cycle_step(0, 0, None)

        self.accepted_at = None
        await self.cycle_step(1, 0, t)          # setup phase
        access_cycles = 0
        while True:
            taken, done, prdata, pslverr = await self.cycle_step(1, 1, t)
            access_cycles += 1
            if done:
                break
            if access_cycles > 64:
                raise AssertionError(f"transfer to {t.addr:#x} never completed")

        if self.accepted_at is None:
            raise AssertionError(f"transfer to {t.addr:#x} completed without a "
                                 "register request")
        rdata, error = self.pending
        if REGISTERED:
            # PREADY rises on the edge after the request is accepted, so the
            # transfer completes one cycle later.
            assert_eq(self.cycle - self.accepted_at, 1,
                      f"{t.addr:#x}: registered response latency")
        else:
            assert_eq(self.cycle, self.accepted_at,
                      f"{t.addr:#x}: direct response completes on acceptance")
        assert_eq(int(pslverr), int(error), f"{t.addr:#x}: PSLVERR")
        if not t.write:
            assert_eq(prdata, rdata, f"{t.addr:#x}: PRDATA")
        return Completion(t, prdata, pslverr)

    async def run(self, transfers: list[Transfer]) -> list[Completion]:
        issued = len(self.regs.accepted)
        done = [await self.transfer(t) for t in transfers]
        await self.cycle_step(0, 0, None)
        assert_eq(len(self.regs.accepted) - issued, len(transfers), "requests issued")
        return done


async def setup(dut, name: str, **block) -> Harness:
    dut._log.info("apb_slave: ADDR_WIDTH=%d DATA_WIDTH=%d REGISTERED=%d, %s",
                  ADDR_WIDTH, DATA_WIDTH, REGISTERED, describe())
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    regs = RegisterBlock(RandomStream(name), **block)
    harness = Harness(dut, domain, regs)
    await harness.reset()
    return harness


def assert_same(actual: list[int], expected: list[int], message: str) -> None:
    """assert_eq for lists, which it does not compare."""
    assert_eq(len(actual), len(expected), f"{message}: length")
    for i, (a, e) in enumerate(zip(actual, expected)):
        assert_eq(a, e, f"{message}[{i}]")


def aligned(rng: RandomStream) -> int:
    return rng.uint(ADDR_WIDTH) & ADDR_MASK & ~(STRB_WIDTH - 1)


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: PREADY, PSLVERR and reg_valid low out of reset."""
    h = await setup(dut, "apb_reset")
    for _ in range(3):
        await h.cycle_step(0, 0, None)
        if REGISTERED:
            assert_eq(int(dut.pready.value), 0, "pready idle")
            assert_eq(int(dut.pslverr.value), 0, "pslverr idle")
        assert_eq(int(dut.reg_valid.value), 0, "reg_valid idle")


@cocotb.test()
async def test_write_then_read(dut) -> None:
    """Directed: zero-wait writes read back, with the minimum cycle count."""
    h = await setup(dut, "apb_basic")
    rng = h.regs.rng
    addrs = [0, STRB_WIDTH, 2 * STRB_WIDTH, ADDR_MASK & ~(STRB_WIDTH - 1)]
    values = [rng.uint(DATA_WIDTH) for _ in addrs]
    start = h.cycle
    await h.run([Transfer(True, a, v) for a, v in zip(addrs, values)])
    # Setup + access, plus the registered wait state, and the trailing idle.
    assert_eq(h.cycle - start, len(addrs) * (2 + REGISTERED) + 1,
              "cycles for zero-wait writes")
    done = await h.run([Transfer(False, a) for a in addrs])
    for c, v in zip(done, values):
        assert_eq(c.rdata, v, f"read back {c.transfer.addr:#x}")


@cocotb.test()
async def test_wait_states(dut) -> None:
    """Directed: a register block that stalls holds the transfer."""
    h = await setup(dut, "apb_wait", wait_probability=0.8, max_wait=6)
    rng = h.regs.rng
    transfers = []
    for _ in range(40):
        a = aligned(rng)
        transfers += [Transfer(True, a, rng.uint(DATA_WIDTH)), Transfer(False, a)]
    done = await h.run(transfers)
    for w, r in zip(done[0::2], done[1::2]):
        assert_eq(r.rdata, w.transfer.data, f"read after stalled write {w.transfer.addr:#x}")


@cocotb.test()
async def test_slave_error(dut) -> None:
    """Directed: reg_error becomes PSLVERR, for reads and for writes."""
    h = await setup(dut, "apb_error")
    bad = 5 * STRB_WIDTH
    h.regs.error_words = {h.regs.index(bad)}
    done = await h.run([Transfer(True, bad, DATA_MASK), Transfer(False, bad),
                        Transfer(True, 0, 1), Transfer(False, 0)])
    assert_same([int(c.error) for c in done], [1, 1, 0, 0], "PSLVERR per transfer")
    assert_eq(done[3].rdata, 1, "good register after a failed one")


@cocotb.test()
async def test_byte_strobes(dut) -> None:
    """Directed: PSTRB reaches reg_strb on writes and is zero on reads."""
    h = await setup(dut, "apb_strobe")
    transfers = [Transfer(True, 0, DATA_MASK)]
    expected = DATA_MASK
    for byte in range(STRB_WIDTH):
        transfers.append(Transfer(True, 0, 0, strb=1 << byte))
        expected &= ~(0xFF << (8 * byte))
    transfers.append(Transfer(False, 0, strb=STRB_MASK))
    done = await h.run(transfers)
    assert_eq(done[-1].rdata, expected & DATA_MASK, "every lane cleared")
    assert_eq(h.regs.accepted[-1].strb, 0, "reg_strb on a read")


@cocotb.test()
async def test_back_to_back(dut) -> None:
    """Directed: transfers with no idle cycle between them."""
    h = await setup(dut, "apb_b2b")
    rng = h.regs.rng
    transfers = [Transfer(bool(i % 2 == 0), (i // 2) * STRB_WIDTH, rng.uint(DATA_WIDTH),
                          prot=rng.uint(3)) for i in range(32)]
    done = await h.run(transfers)
    for w, r in zip(done[0::2], done[1::2]):
        assert_eq(r.rdata, w.transfer.data, "back-to-back read back")
    assert_same([a.prot for a in h.regs.accepted], [t.prot for t in transfers],
              "PPROT forwarded")


@cocotb.test()
async def test_reset_mid_transfer(dut) -> None:
    """Directed: a reset during a stalled transfer leaves no stale response."""
    h = await setup(dut, "apb_midreset", wait_probability=1.0, max_wait=100)
    t = Transfer(False, 0)
    await h.cycle_step(1, 0, t)
    for _ in range(3):
        await h.cycle_step(1, 1, t)
    await h.reset()
    h.regs.wait_probability = 0.0
    for _ in range(3):
        await h.cycle_step(0, 0, None)
        if REGISTERED:
            assert_eq(int(dut.pready.value), 0, "pready after reset")
    h.regs.accepted.clear()
    await h.run([Transfer(True, 0, 7), Transfer(False, 0)])
    assert_eq(len(h.regs.accepted), 2, "requests after reset")


# ---------------------------------------------------------------------------
# Randomised
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_transfers(dut) -> None:
    """Randomised: transfers, gaps, waits, strobes, protection and errors."""
    h = await setup(dut, "apb_random", wait_probability=0.4, max_wait=4)
    rng = h.regs.rng
    h.regs.error_words = {rng.uint(ADDR_WIDTH) // STRB_WIDTH for _ in range(8)}
    pool = [aligned(rng) for _ in range(16)] + [rng.uint(ADDR_WIDTH) for _ in range(4)]
    transfers = [Transfer(rng.boolean(), rng.choice(pool), rng.corner_uint(DATA_WIDTH),
                          strb=rng.uint(STRB_WIDTH), prot=rng.uint(3),
                          gap=rng.delay(max_idle=2))
                 for _ in range(1500)]
    shadow: dict[int, int] = {}
    for c in await h.run(transfers):
        t = c.transfer
        index = t.addr // STRB_WIDTH
        bad = index in h.regs.error_words
        assert_eq(int(c.error), int(bad), f"PSLVERR {t.addr:#x}")
        if t.write and not bad:
            word = shadow.get(index, 0)
            for byte in range(STRB_WIDTH):
                if t.strb >> byte & 1:
                    lane = 0xFF << (8 * byte)
                    word = (word & ~lane) | (t.data & lane)
            shadow[index] = word
        elif not t.write:
            assert_eq(c.rdata, shadow.get(index, 0), f"read {t.addr:#x}")
