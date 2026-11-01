"""Cocotb regression for bram_ctrl.

Coverage
    directed   reset state, a single write and read, byte-enable masking,
               one response per accepted request, responses held under
               back-pressure, out-of-range addresses answered with an error
    randomised interleaved requests with randomised back-pressure on the
               response channel, compared against a reference dictionary
    regression sustained one-request-per-cycle streaming, and a mid-stream
               reset

The property that matters most is the flow-control invariant: a request is
only accepted when there is guaranteed room for its result. If that is ever
wrong, a read result arrives with nowhere to go and is silently dropped — the
kind of bug that shows up as one corrupted word an hour under load.
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import ReadOnly, RisingEdge

from socip import (
    ClockDomain,
    RandomStream,
    assert_eq,
    describe,
    get_param,
    sample,
    sampled,
)

DATA_WIDTH = get_param("DATA_WIDTH", 32)
DEPTH = get_param("DEPTH", 1024)
WRITE_RESPONSE = get_param("WRITE_RESPONSE", 1)

CLK_PERIOD_NS = 10.0
DATA_MASK = (1 << DATA_WIDTH) - 1
NUM_BYTES = DATA_WIDTH // 8
ALL_BYTES = (1 << NUM_BYTES) - 1
ADDR_WIDTH = max(1, (DEPTH - 1).bit_length())
ADDR_SPACE = 1 << ADDR_WIDTH


def merge(old: int, new: int, be: int) -> int:
    result = old
    for byte in range(NUM_BYTES):
        if (be >> byte) & 1:
            mask = 0xFF << (byte * 8)
            result = (result & ~mask) | (new & mask)
    return result & DATA_MASK


class ResponseCollector:
    """Records every response in order."""

    def __init__(self, dut) -> None:
        self.dut = dut
        self.responses: list[tuple[int, int]] = []   # (rdata, err)
        self._task = None

    def start(self) -> "ResponseCollector":
        self._task = cocotb.start_soon(self._run())
        return self

    def stop(self) -> None:
        if self._task is not None:
            self._task.kill()
            self._task = None

    async def _run(self) -> None:
        while True:
            await RisingEdge(self.dut.clk)
            valid, ready, rdata, err, rst_n = await sample(
                self.dut.rsp_valid, self.dut.rsp_ready, self.dut.rsp_rdata,
                self.dut.rsp_err, self.dut.rst_n)
            if rst_n and valid and ready:
                self.responses.append((rdata, err))


async def bring_up(dut) -> tuple[ClockDomain, ResponseCollector]:
    dut._log.info("bram_ctrl: DATA_WIDTH=%d, DEPTH=%d, WRITE_RESPONSE=%d, %s",
                  DATA_WIDTH, DEPTH, WRITE_RESPONSE, describe())

    dut.req_valid.value = 0
    dut.req_we.value = 0
    dut.req_addr.value = 0
    dut.req_be.value = ALL_BYTES
    dut.req_wdata.value = 0
    dut.rsp_ready.value = 1

    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    await domain.reset()
    return domain, ResponseCollector(dut).start()


async def request(dut, we: int, addr: int, wdata: int = 0,
                  be: int = ALL_BYTES) -> None:
    """Issue exactly one request, waiting for it to be accepted.

    Ready is sampled in the ``ReadOnly`` phase and the transfer completes at
    the edge that follows, which is the same discipline ``StreamSource`` uses.
    Sampling after the edge instead would leave req_valid asserted across a
    second ready cycle and issue the request twice.
    """
    dut.req_valid.value = 1
    dut.req_we.value = we
    dut.req_addr.value = addr
    dut.req_be.value = be
    dut.req_wdata.value = wdata & DATA_MASK

    while True:
        await ReadOnly()
        if int(dut.req_ready.value) == 1:
            break
        await RisingEdge(dut.clk)

    await RisingEdge(dut.clk)
    dut.req_valid.value = 0


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: ready for a request, no response pending."""
    await bring_up(dut)
    req_ready, rsp_valid = await sample(dut.req_ready, dut.rsp_valid)
    assert_eq(req_ready, 1, "req_ready after reset")
    assert_eq(rsp_valid, 0, "rsp_valid after reset")


@cocotb.test()
async def test_write_then_read(dut) -> None:
    """Directed: a written word reads back, and both are answered."""
    domain, collector = await bring_up(dut)

    await request(dut, 1, 0x10, 0xDEAD_BEEF)
    await request(dut, 0, 0x10)
    await domain.cycles(6)

    expected_responses = 2 if WRITE_RESPONSE else 1
    assert_eq(len(collector.responses), expected_responses,
              "one response per accepted request")

    rdata, err = collector.responses[-1]
    assert_eq(rdata, 0xDEAD_BEEF & DATA_MASK, "read data")
    assert_eq(err, 0, "no error on a valid address")


@cocotb.test()
async def test_byte_enables(dut) -> None:
    """Directed: only the enabled byte lanes are written."""
    domain, collector = await bring_up(dut)
    addr = 0x20

    await request(dut, 1, addr, 0x0000_0000)
    expected = 0

    for byte in range(NUM_BYTES):
        await request(dut, 1, addr, DATA_MASK, be=1 << byte)
        expected = merge(expected, DATA_MASK, 1 << byte)

        collector.responses.clear()
        await request(dut, 0, addr)
        await domain.cycles(6)
        assert_eq(collector.responses[-1][0], expected,
                  f"after enabling byte lane {byte}")


@cocotb.test()
async def test_response_held_under_backpressure(dut) -> None:
    """Directed: a response waits for the consumer rather than being dropped."""
    domain, _collector = await bring_up(dut)

    await request(dut, 1, 0x30, 0x1234_5678)
    await domain.cycles(4)

    await domain.edge()
    dut.rsp_ready.value = 0
    await request(dut, 0, 0x30)

    # Wait for the response to appear, then confirm it stays put.
    for _ in range(8):
        await RisingEdge(dut.clk)
        if await sampled(dut.rsp_valid):
            break
    else:
        raise AssertionError("no response appeared with the consumer stalled")

    for cycle in range(6):
        await RisingEdge(dut.clk)
        valid, rdata = await sample(dut.rsp_valid, dut.rsp_rdata)
        assert_eq(valid, 1, f"rsp_valid held at stall cycle {cycle}")
        assert_eq(rdata, 0x1234_5678 & DATA_MASK,
                  f"rsp_rdata held at stall cycle {cycle}")

    await domain.edge()
    dut.rsp_ready.value = 1
    await domain.cycles(4)


@cocotb.test()
async def test_out_of_range_address_reports_error(dut) -> None:
    """Directed: an address past the array is answered with rsp_err.

    Silently aliasing a bad address onto a good one turns a software bug into
    corrupted data somewhere unrelated, which is far harder to find.
    """
    if DEPTH == ADDR_SPACE:
        dut._log.info("DEPTH is a power of two: every address is in range")
        return

    domain, collector = await bring_up(dut)
    collector.responses.clear()

    await request(dut, 0, ADDR_SPACE - 1)
    await domain.cycles(6)

    assert len(collector.responses) >= 1, "no response to the bad address"
    _rdata, err = collector.responses[-1]
    assert_eq(err, 1, "rsp_err on an out-of-range address")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_traffic(dut) -> None:
    """Randomised: interleaved requests with response back-pressure."""
    rng = RandomStream("bram_ctrl")
    dut._log.info("random seed = %d", rng.seed)
    domain, collector = await bring_up(dut)

    async def backpressure() -> None:
        while True:
            await RisingEdge(dut.clk)
            dut.rsp_ready.value = int(rng.boolean(0.7))

    cocotb.start_soon(backpressure())

    window = min(DEPTH, 64)
    model: dict[int, int] = {}

    # Responses are counted cumulatively rather than cleared before each read.
    # With WRITE_RESPONSE enabled and the consumer throttled, a backlog of
    # write responses is normally outstanding, so "the next response to
    # arrive" is not necessarily the one belonging to this read. Responses are
    # returned strictly in order, so the read's answer is at a known index.
    expected_total = 0

    for addr in range(window):
        await request(dut, 1, addr, 0)
        expected_total += 1 if WRITE_RESPONSE else 0
        model[addr] = 0

    for operation in range(300):
        addr = rng.between(0, window - 1)
        if rng.boolean(0.5):
            data = rng.corner_uint(DATA_WIDTH)
            be = rng.between(1, ALL_BYTES)
            await request(dut, 1, addr, data, be)
            expected_total += 1 if WRITE_RESPONSE else 0
            model[addr] = merge(model[addr], data, be)
        else:
            await request(dut, 0, addr)
            expected_total += 1

            for _ in range(200):
                if len(collector.responses) >= expected_total:
                    break
                await RisingEdge(dut.clk)
            else:
                raise AssertionError(
                    f"operation {operation}: only "
                    f"{len(collector.responses)} of {expected_total} "
                    f"responses arrived")

            assert_eq(collector.responses[expected_total - 1][0], model[addr],
                      f"operation {operation}, address {addr}")

    dut.rsp_ready.value = 1
    await domain.cycles(4)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_sustained_streaming(dut) -> None:
    """Regression: one request per cycle, sustained, with no stalls.

    This is the case the two-entry response buffer exists for: with a single
    entry the controller would idle every time the consumer paused for a
    cycle.
    """
    domain, collector = await bring_up(dut)
    count = 200

    collector.responses.clear()
    for addr in range(count):
        await request(dut, 1, addr % min(DEPTH, 128),
                      (addr * 0x0101_0101) & DATA_MASK)

    await domain.cycles(8)
    if WRITE_RESPONSE:
        assert_eq(len(collector.responses), count,
                  "one response per accepted write")

    collector.responses.clear()
    for addr in range(min(DEPTH, 128)):
        await request(dut, 0, addr)
    await domain.cycles(8)

    assert_eq(len(collector.responses), min(DEPTH, 128),
              "one response per accepted read")


@cocotb.test()
async def test_reset_during_traffic(dut) -> None:
    """Regression: a mid-stream reset clears the pipeline and it restarts."""
    domain, collector = await bring_up(dut)

    for addr in range(8):
        await request(dut, 1, addr, (0x1000 + addr) & DATA_MASK)

    dut.req_valid.value = 0
    await domain.reset()

    req_ready, rsp_valid = await sample(dut.req_ready, dut.rsp_valid)
    assert_eq(req_ready, 1, "req_ready after mid-stream reset")
    assert_eq(rsp_valid, 0, "rsp_valid after mid-stream reset")

    # The array is not reset, so the data written before the reset survives.
    await domain.edge()
    collector.responses.clear()
    await request(dut, 0, 3)
    await domain.cycles(6)

    assert collector.responses, "no response after the reset"
    assert_eq(collector.responses[-1][0], 0x1003 & DATA_MASK,
              "data written before the reset must survive it")
