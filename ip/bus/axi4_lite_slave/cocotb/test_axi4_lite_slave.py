"""Cocotb regression for axi4_lite_slave.

Coverage
    directed   the reset state, a write and a read, write data before, with
               and after its address, wait states from a slow register block,
               SLVERR on reads and writes, byte strobes, a stalled B channel
               that does not stall reads (and the reverse), fair alternation
               when both directions are saturated, and a reset with
               transfers in flight
    randomised every channel's valid and ready delays, the AW/W skew,
               strobes, protection, errors and wait states, against a
               register model
    regression one register request per transfer, responses in order, and
               no combinational path from the register response to any AXI
               output

The manager and the register block are written from the specifications -
AMBA AXI4-Lite for the channels, the RTL header for the register port - not
from the RTL. One coroutine runs every cycle in a fixed order: drive every
channel after the edge, let it settle, read the register request and the AXI
outputs, drive the register response, read the AXI outputs again, and
resolve the handshakes the next edge will see.
"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from itertools import groupby

import cocotb
from cocotb.triggers import RisingEdge, Timer

from socip import ClockDomain, RandomStream, assert_eq, describe, get_param

ADDR_WIDTH = get_param("ADDR_WIDTH", 12)
DATA_WIDTH = get_param("DATA_WIDTH", 32)

CLK_PERIOD_NS = 10.0
STRB_WIDTH = DATA_WIDTH // 8
ADDR_MASK = (1 << ADDR_WIDTH) - 1
DATA_MASK = (1 << DATA_WIDTH) - 1
STRB_MASK = (1 << STRB_WIDTH) - 1
OKAY, SLVERR = 0, 2

AXI_OUTPUTS = ["s_axi_awready", "s_axi_wready", "s_axi_arready", "s_axi_bvalid",
               "s_axi_bresp", "s_axi_rvalid", "s_axi_rdata", "s_axi_rresp"]


@dataclass
class Write:
    addr: int
    data: int
    strb: int = STRB_MASK
    prot: int = 0
    aw_delay: int = 0     # cycles before AWVALID rises
    w_delay: int = 0      # cycles before WVALID rises


@dataclass
class Read:
    addr: int
    prot: int = 0
    delay: int = 0


@dataclass
class Channel:
    """One manager-driven channel: a queue of beats, each after a delay."""

    beats: deque = field(default_factory=deque)
    wait: int | None = None

    def current(self, delay_of) -> object | None:
        if not self.beats:
            return None
        if self.wait is None:
            self.wait = delay_of(self.beats[0])
        if self.wait > 0:
            return None
        return self.beats[0]

    def tick(self) -> None:
        if self.wait:
            self.wait -= 1

    def pop(self) -> None:
        self.beats.popleft()
        self.wait = None


@dataclass
class RegisterBlock:
    rng: RandomStream
    words: dict[int, int] = field(default_factory=dict)
    error_words: set[int] = field(default_factory=set)
    wait_probability: float = 0.0
    max_wait: int = 0
    waited: int = 0

    def index(self, addr: int) -> int:
        return addr // STRB_WIDTH

    def read(self, addr: int) -> int:
        return self.words.get(self.index(addr), 0)

    def error(self, addr: int) -> bool:
        return self.index(addr) in self.error_words

    def ready(self) -> bool:
        if self.waited < self.max_wait and self.rng.boolean(self.wait_probability):
            self.waited += 1
            return False
        self.waited = 0
        return True

    def write(self, addr: int, data: int, strb: int) -> None:
        if self.error(addr):
            return
        word = self.read(addr)
        for byte in range(STRB_WIDTH):
            if strb >> byte & 1:
                lane = 0xFF << (8 * byte)
                word = (word & ~lane) | (data & lane)
        self.words[self.index(addr)] = word & DATA_MASK


class Harness:
    def __init__(self, dut, domain: ClockDomain, regs: RegisterBlock) -> None:
        self.dut = dut
        self.domain = domain
        self.regs = regs
        self.rng = regs.rng
        self.aw = Channel()
        self.w = Channel()
        self.ar = Channel()
        self.bready_probability = 1.0
        self.rready_probability = 1.0
        self.expected_b: deque[tuple[Write, int]] = deque()
        self.expected_r: deque[tuple[Read, int, int]] = deque()
        self.writes_issued: deque[Write] = deque()
        self.reads_issued: deque[Read] = deque()
        self.b_seen: list[tuple[Write, int]] = []
        self.r_seen: list[tuple[Read, int, int]] = []
        self.order: list[str] = []
        self.cycle = 0

    def idle(self) -> None:
        d = self.dut
        for name in ["awvalid", "awaddr", "awprot", "wvalid", "wdata", "wstrb",
                     "bready", "arvalid", "araddr", "arprot", "rready"]:
            getattr(d, f"s_axi_{name}").value = 0
        d.reg_ready.value = 0
        d.reg_rdata.value = 0
        d.reg_error.value = 0

    async def reset(self) -> None:
        self.idle()
        await self.domain.reset()
        for ch in (self.aw, self.w, self.ar):
            ch.beats.clear()
            ch.wait = None
        for q in (self.expected_b, self.expected_r, self.writes_issued,
                  self.reads_issued):
            q.clear()

    def queue(self, ops: list[Write | Read]) -> None:
        for op in ops:
            if isinstance(op, Write):
                self.aw.beats.append(op)
                self.w.beats.append(op)
                self.writes_issued.append(op)
            else:
                self.ar.beats.append(op)
                self.reads_issued.append(op)

    def outputs(self) -> list[int]:
        return [int(getattr(self.dut, n).value) for n in AXI_OUTPUTS]

    async def step(self) -> None:
        d = self.dut
        aw = self.aw.current(lambda op: op.aw_delay)
        w = self.w.current(lambda op: op.w_delay)
        ar = self.ar.current(lambda op: op.delay)
        d.s_axi_awvalid.value = int(aw is not None)
        d.s_axi_awaddr.value = aw.addr if aw else 0
        d.s_axi_awprot.value = aw.prot if aw else 0
        d.s_axi_wvalid.value = int(w is not None)
        d.s_axi_wdata.value = w.data if w else 0
        d.s_axi_wstrb.value = w.strb if w else 0
        d.s_axi_arvalid.value = int(ar is not None)
        d.s_axi_araddr.value = ar.addr if ar else 0
        d.s_axi_arprot.value = ar.prot if ar else 0
        d.s_axi_bready.value = int(self.rng.boolean(self.bready_probability))
        d.s_axi_rready.value = int(self.rng.boolean(self.rready_probability))

        await Timer(CLK_PERIOD_NS / 4, units="ns")
        before = self.outputs()
        valid = int(d.reg_valid.value)
        write = int(d.reg_write.value)
        addr = int(d.reg_addr.value)
        wdata = int(d.reg_wdata.value)
        strb = int(d.reg_strb.value)
        prot = int(d.reg_prot.value)
        ready = self.regs.ready() if valid else self.rng.boolean()
        d.reg_ready.value = int(ready)
        d.reg_rdata.value = self.regs.read(addr) if valid and not write \
            else self.rng.uint(DATA_WIDTH)
        d.reg_error.value = int(self.regs.error(addr)) if valid \
            else int(self.rng.boolean())

        await Timer(CLK_PERIOD_NS / 4, units="ns")
        after = self.outputs()
        for name, b, a in zip(AXI_OUTPUTS, before, after):
            assert_eq(a, b, f"cycle {self.cycle}: {name} followed the register "
                      "response combinationally")
        awready, wready, arready, bvalid, bresp, rvalid, rdata, rresp = after
        bready = int(d.s_axi_bready.value)
        rready = int(d.s_axi_rready.value)

        await RisingEdge(d.clk)
        self.cycle += 1
        for ch in (self.aw, self.w, self.ar):
            ch.tick()

        if aw is not None and awready:
            self.aw.pop()
        if w is not None and wready:
            self.w.pop()
        if ar is not None and arready:
            self.ar.pop()

        if valid and ready:
            error = self.regs.error(addr)
            resp = SLVERR if error else OKAY
            if write:
                op = self.writes_issued.popleft()
                assert_eq(addr, op.addr, f"cycle {self.cycle}: write reg_addr")
                assert_eq(wdata, op.data, f"cycle {self.cycle}: reg_wdata")
                assert_eq(strb, op.strb, f"cycle {self.cycle}: reg_strb")
                assert_eq(prot, op.prot, f"cycle {self.cycle}: write reg_prot")
                self.regs.write(addr, wdata, strb)
                self.expected_b.append((op, resp))
                self.order.append("W")
            else:
                op = self.reads_issued.popleft()
                assert_eq(addr, op.addr, f"cycle {self.cycle}: read reg_addr")
                assert_eq(strb, 0, f"cycle {self.cycle}: reg_strb on a read")
                assert_eq(wdata, 0, f"cycle {self.cycle}: reg_wdata on a read")
                assert_eq(prot, op.prot, f"cycle {self.cycle}: read reg_prot")
                self.expected_r.append((op, self.regs.read(addr), resp))
                self.order.append("R")

        if bvalid and bready:
            if not self.expected_b:
                raise AssertionError(f"cycle {self.cycle}: B with no write")
            op, resp = self.expected_b.popleft()
            assert_eq(bresp, resp, f"cycle {self.cycle}: BRESP for {op.addr:#x}")
            self.b_seen.append((op, bresp))
        if rvalid and rready:
            if not self.expected_r:
                raise AssertionError(f"cycle {self.cycle}: R with no read")
            op, data, resp = self.expected_r.popleft()
            assert_eq(rresp, resp, f"cycle {self.cycle}: RRESP for {op.addr:#x}")
            if resp == OKAY:
                assert_eq(rdata, data, f"cycle {self.cycle}: RDATA for {op.addr:#x}")
            self.r_seen.append((op, rdata, rresp))

    def busy(self) -> bool:
        return bool(self.aw.beats or self.w.beats or self.ar.beats
                    or self.writes_issued or self.reads_issued
                    or self.expected_b or self.expected_r)

    async def run(self, ops: list[Write | Read], limit: int = 200000) -> None:
        b0, r0 = len(self.b_seen), len(self.r_seen)
        self.queue(ops)
        start = self.cycle
        while self.busy():
            await self.step()
            if self.cycle - start > limit:
                raise AssertionError("transfers did not complete")
        writes = sum(isinstance(op, Write) for op in ops)
        assert_eq(len(self.b_seen) - b0, writes, "B responses")
        assert_eq(len(self.r_seen) - r0, len(ops) - writes, "R responses")


async def setup(dut, name: str, **block) -> Harness:
    dut._log.info("axi4_lite_slave: ADDR_WIDTH=%d DATA_WIDTH=%d, %s",
                  ADDR_WIDTH, DATA_WIDTH, describe())
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    h = Harness(dut, domain, RegisterBlock(RandomStream(name), **block))
    await h.reset()
    return h


def aligned(rng: RandomStream) -> int:
    return rng.uint(ADDR_WIDTH) & ~(STRB_WIDTH - 1)


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: no response valid, every channel ready, no request."""
    h = await setup(dut, "axil_reset")
    for _ in range(3):
        await h.step()
    assert_eq(int(dut.s_axi_bvalid.value), 0, "bvalid")
    assert_eq(int(dut.s_axi_rvalid.value), 0, "rvalid")
    assert_eq(int(dut.reg_valid.value), 0, "reg_valid")
    for name in ["awready", "wready", "arready"]:
        assert_eq(int(getattr(dut, f"s_axi_{name}").value), 1, name)


@cocotb.test()
async def test_write_then_read(dut) -> None:
    """Directed: writes read back through the register block."""
    h = await setup(dut, "axil_basic")
    addrs = sorted({0, STRB_WIDTH & ADDR_MASK, ADDR_MASK & ~(STRB_WIDTH - 1)})
    values = [h.rng.uint(DATA_WIDTH) for _ in addrs]
    await h.run([Write(a, v) for a, v in zip(addrs, values)])
    await h.run([Read(a) for a in addrs])
    for (op, data, _), v in zip(h.r_seen, values):
        assert_eq(data, v, f"read back {op.addr:#x}")


@cocotb.test()
async def test_address_data_skew(dut) -> None:
    """Directed: W before, with and after AW, by up to five cycles.

    AXI orders nothing between the read and write channels, so each read is
    issued only once its write's B response has arrived, as a manager must.
    """
    h = await setup(dut, "axil_skew")
    skews = [(0, 0), (0, 5), (5, 0), (2, 3), (3, 2), (0, 1), (1, 0)]
    for i, (aw_d, w_d) in enumerate(skews):
        a = (i * STRB_WIDTH) & ADDR_MASK
        await h.run([Write(a, 0x1000 + i, aw_delay=aw_d, w_delay=w_d)])
        await h.run([Read(a)])
        assert_eq(h.r_seen[-1][1], 0x1000 + i, f"skewed write {i} read back")


@cocotb.test()
async def test_wait_states(dut) -> None:
    """Directed: a register block that stalls holds the request."""
    h = await setup(dut, "axil_wait", wait_probability=0.8, max_wait=6)
    ops: list[Write | Read] = []
    for _ in range(40):
        a = aligned(h.rng)
        ops += [Write(a, h.rng.uint(DATA_WIDTH)), Read(a)]
    await h.run(ops)


@cocotb.test()
async def test_slave_error(dut) -> None:
    """Directed: reg_error becomes SLVERR on B and on R."""
    h = await setup(dut, "axil_error")
    bad = (3 * STRB_WIDTH) & ADDR_MASK
    h.regs.error_words = {h.regs.index(bad)}
    await h.run([Write(bad, DATA_MASK), Write(0, 9)])
    await h.run([Read(bad), Read(0)])
    assert_eq(h.b_seen[0][1], SLVERR, "BRESP for the bad word")
    assert_eq(h.b_seen[1][1], OKAY, "BRESP for the good word")
    assert_eq(h.r_seen[0][2], SLVERR, "RRESP for the bad word")
    assert_eq(h.r_seen[1][1], 9, "good word after a failed one")


@cocotb.test()
async def test_byte_strobes(dut) -> None:
    """Directed: WSTRB selects lanes."""
    h = await setup(dut, "axil_strobe")
    ops: list[Write] = [Write(0, DATA_MASK)]
    expected = DATA_MASK
    for byte in range(STRB_WIDTH):
        ops.append(Write(0, 0, strb=1 << byte))
        expected &= ~(0xFF << (8 * byte))
    await h.run(ops)
    await h.run([Read(0)])
    assert_eq(h.r_seen[-1][1], expected & DATA_MASK, "every lane cleared")


@cocotb.test()
async def test_response_backpressure(dut) -> None:
    """Directed: a stalled B channel does not stall reads, and the reverse."""
    h = await setup(dut, "axil_bp")
    h.bready_probability = 0.0
    h.queue([Write(0, 1), Write(STRB_WIDTH & ADDR_MASK, 2)])
    for _ in range(10):
        await h.step()
    assert_eq(len(h.b_seen), 0, "no B while BREADY is low")
    assert_eq(int(dut.s_axi_bvalid.value), 1, "B held")
    h.queue([Read(0), Read(0), Read(0)])
    for _ in range(20):
        await h.step()
    assert_eq(len(h.r_seen), 3, "reads complete past a stalled B")
    h.bready_probability = 1.0
    h.rready_probability = 0.0
    h.queue([Read(STRB_WIDTH & ADDR_MASK), Write((2 * STRB_WIDTH) & ADDR_MASK, 3)])
    for _ in range(20):
        await h.step()
    assert_eq(len(h.b_seen), 3, "writes complete past a stalled R")
    h.rready_probability = 1.0
    while h.busy():
        await h.step()


@cocotb.test()
async def test_fair_alternation(dut) -> None:
    """Directed: saturated reads and writes strictly alternate on the register
    port, with and without wait states."""
    for wait in (0.0, 0.6):
        h = await setup(dut, f"axil_fair_{wait}", wait_probability=wait, max_wait=3)
        ops: list[Write | Read] = []
        for i in range(30):
            a = (i * STRB_WIDTH) & ADDR_MASK
            ops += [Write(a, i), Read(a)]
        await h.run(ops)
        longest = max(len(list(run)) for _, run in groupby(h.order))
        assert_eq(longest, 1, f"longest same-direction run in {''.join(h.order)}")


@cocotb.test()
async def test_reset_in_flight(dut) -> None:
    """Directed: a reset with transfers in flight leaves nothing behind."""
    h = await setup(dut, "axil_midreset", wait_probability=1.0, max_wait=1000)
    h.queue([Write(0, 1), Read(0)])
    for _ in range(6):
        await h.step()
    await h.reset()
    h.regs.wait_probability = 0.0
    for _ in range(3):
        await h.step()
    assert_eq(int(dut.s_axi_bvalid.value), 0, "bvalid after reset")
    assert_eq(int(dut.s_axi_rvalid.value), 0, "rvalid after reset")
    assert_eq(int(dut.reg_valid.value), 0, "reg_valid after reset")
    a = (4 * STRB_WIDTH) & ADDR_MASK
    await h.run([Write(a, 5)])
    await h.run([Read(a)])
    assert_eq(h.r_seen[-1][1], 5, "transfer after reset")


# ---------------------------------------------------------------------------
# Randomised
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_traffic(dut) -> None:
    """Randomised: delays, skew, back-pressure, strobes, errors and waits."""
    h = await setup(dut, "axil_random", wait_probability=0.35, max_wait=4)
    rng = h.rng
    h.bready_probability = 0.7
    h.rready_probability = 0.7
    h.regs.error_words = {rng.uint(ADDR_WIDTH) // STRB_WIDTH for _ in range(6)}
    pool = [aligned(rng) for _ in range(16)] + [rng.uint(ADDR_WIDTH) for _ in range(4)]
    ops: list[Write | Read] = []
    for _ in range(1500):
        if rng.boolean():
            ops.append(Write(rng.choice(pool), rng.corner_uint(DATA_WIDTH),
                             strb=rng.uint(STRB_WIDTH), prot=rng.uint(3),
                             aw_delay=rng.delay(3), w_delay=rng.delay(3)))
        else:
            ops.append(Read(rng.choice(pool), prot=rng.uint(3), delay=rng.delay(3)))
    await h.run(ops)
