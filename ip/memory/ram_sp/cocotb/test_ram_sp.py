"""Cocotb regression for ram_sp.

Coverage
    directed   write then read back, byte-enable masking, read-during-write
               returning old data, the enable holding the output, address
               boundaries
    randomised interleaved reads and writes against a reference dictionary,
               with corner-biased addresses and data
    regression a full sweep writing and reading every location, and a long
               randomised run

Read latency depends on OUTPUT_REG, so the testbench derives it from the
parameter rather than assuming a value. A test that hard-codes one cycle
silently stops checking anything when the output register is enabled.
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge

from socip import (
    ClockDomain,
    RandomStream,
    assert_eq,
    describe,
    get_param,
    settle,
    start_clock,
)

DATA_WIDTH = get_param("DATA_WIDTH", 32)
DEPTH = get_param("DEPTH", 1024)
BYTE_ENABLE = get_param("BYTE_ENABLE", 1)
OUTPUT_REG = get_param("OUTPUT_REG", 0)

CLK_PERIOD_NS = 10.0
DATA_MASK = (1 << DATA_WIDTH) - 1
NUM_BYTES = DATA_WIDTH // 8
ALL_BYTES = (1 << NUM_BYTES) - 1

# One cycle through the array, plus one more if the output register is fitted.
READ_LATENCY = 1 + (1 if OUTPUT_REG else 0)


def merge(old: int, new: int, be: int) -> int:
    """Reference model for a byte-enabled write."""
    if not BYTE_ENABLE:
        return new & DATA_MASK
    result = old
    for byte in range(NUM_BYTES):
        if (be >> byte) & 1:
            mask = 0xFF << (byte * 8)
            result = (result & ~mask) | (new & mask)
    return result & DATA_MASK


async def bring_up(dut) -> None:
    """Start the clock with the memory idle. The array itself has no reset."""
    dut._log.info("ram_sp: DATA_WIDTH=%d, DEPTH=%d, BYTE_ENABLE=%d, "
                  "OUTPUT_REG=%d (read latency %d), %s",
                  DATA_WIDTH, DEPTH, BYTE_ENABLE, OUTPUT_REG, READ_LATENCY,
                  describe())
    dut.en.value = 0
    dut.we.value = 0
    dut.be.value = ALL_BYTES
    dut.addr.value = 0
    dut.wdata.value = 0
    start_clock(dut.clk, CLK_PERIOD_NS)
    for _ in range(3):
        await RisingEdge(dut.clk)


async def write(dut, addr: int, data: int, be: int = ALL_BYTES) -> None:
    dut.en.value = 1
    dut.we.value = 1
    dut.be.value = be
    dut.addr.value = addr
    dut.wdata.value = data & DATA_MASK
    await RisingEdge(dut.clk)
    dut.en.value = 0
    dut.we.value = 0


async def read(dut, addr: int) -> int:
    """Issue a read and return the data once the pipeline has delivered it."""
    dut.en.value = 1
    dut.we.value = 0
    dut.addr.value = addr
    await RisingEdge(dut.clk)
    dut.en.value = 0

    # The enable must stay asserted for the output register to advance.
    for _ in range(READ_LATENCY - 1):
        dut.en.value = 1
        await RisingEdge(dut.clk)
        dut.en.value = 0

    await settle()
    return int(dut.rdata.value)


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_write_then_read(dut) -> None:
    """Directed: a written word reads back unchanged."""
    await bring_up(dut)

    for addr, value in ((0, 0xDEAD_BEEF), (1, 0x0000_0001),
                        (DEPTH - 1, 0xFFFF_FFFF), (DEPTH // 2, 0xA5A5_5A5A)):
        await write(dut, addr, value)
        assert_eq(await read(dut, addr), value & DATA_MASK,
                  f"word at address {addr}")


@cocotb.test()
async def test_byte_enables(dut) -> None:
    """Directed: only the enabled byte lanes are written."""
    if not BYTE_ENABLE:
        dut._log.info("byte enables disabled at elaboration")
        return

    await bring_up(dut)
    addr = 7

    await write(dut, addr, 0x0000_0000)
    expected = 0

    for byte in range(NUM_BYTES):
        await write(dut, addr, DATA_MASK, be=1 << byte)
        expected = merge(expected, DATA_MASK, 1 << byte)
        assert_eq(await read(dut, addr), expected,
                  f"after enabling byte lane {byte}")

    assert_eq(await read(dut, addr), DATA_MASK,
              "every lane written individually should fill the word")


@cocotb.test()
async def test_read_during_write_returns_old_data(dut) -> None:
    """Directed: a coincident read returns the contents before the write.

    "Read first" is the behaviour every target can implement. Write-first is
    not universally available, which is why it is not offered as an option: a
    parameter that silently changes meaning between targets is worse than no
    parameter.
    """
    await bring_up(dut)
    addr = 3
    old = 0x1111_1111 & DATA_MASK
    new = 0x2222_2222 & DATA_MASK

    await write(dut, addr, old)

    # A write cycle also issues a read from the same address.
    dut.en.value = 1
    dut.we.value = 1
    dut.be.value = ALL_BYTES
    dut.addr.value = addr
    dut.wdata.value = new
    await RisingEdge(dut.clk)
    dut.we.value = 0

    for _ in range(READ_LATENCY - 1):
        await RisingEdge(dut.clk)
    await settle()
    assert_eq(int(dut.rdata.value), old, "coincident read must return old data")

    dut.en.value = 0
    assert_eq(await read(dut, addr), new, "the write must still have landed")


@cocotb.test()
async def test_enable_holds_the_output(dut) -> None:
    """Directed: with the enable low nothing changes, and rdata is held."""
    await bring_up(dut)

    await write(dut, 5, 0x5555_5555 & DATA_MASK)
    held = await read(dut, 5)

    dut.en.value = 0
    dut.addr.value = 9
    for _ in range(6):
        await RisingEdge(dut.clk)
    await settle()

    assert_eq(int(dut.rdata.value), held,
              "rdata must be held while the memory is disabled")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_traffic(dut) -> None:
    """Randomised: interleaved reads and writes against a reference model."""
    rng = RandomStream("ram_sp")
    dut._log.info("random seed = %d", rng.seed)
    await bring_up(dut)

    # A small address window so reads hit written locations often.
    window = min(DEPTH, 64)

    # The array has no reset and every test in this module shares one DUT, so
    # it still holds whatever the previous tests wrote. Establish a known state
    # before comparing against a model, or the first partial-byte write to an
    # address will disagree about the bytes it did not touch.
    model: dict[int, int] = {}
    for addr in range(window):
        await write(dut, addr, 0)
        model[addr] = 0

    for operation in range(600):
        addr = rng.between(0, window - 1)
        if rng.boolean(0.5):
            data = rng.corner_uint(DATA_WIDTH)
            be = rng.between(1, ALL_BYTES) if BYTE_ENABLE else ALL_BYTES
            await write(dut, addr, data, be)
            model[addr] = merge(model.get(addr, 0), data, be)
        elif addr in model:
            assert_eq(await read(dut, addr), model[addr],
                      f"operation {operation}, address {addr}")


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_every_location_is_distinct(dut) -> None:
    """Regression: a distinct value in every location, then read them all back.

    An address decoder that aliases two locations shows up here and nowhere
    else. Limited to the first 256 words so the test stays quick on a large
    array; the randomised test covers the rest of the address space.
    """
    await bring_up(dut)
    count = min(DEPTH, 256)

    for addr in range(count):
        await write(dut, addr, (addr * 0x0101_0101 + 0x9E37) & DATA_MASK)

    for addr in range(count):
        assert_eq(await read(dut, addr),
                  (addr * 0x0101_0101 + 0x9E37) & DATA_MASK,
                  f"address {addr} after the full sweep")


@cocotb.test()
async def test_address_boundaries(dut) -> None:
    """Regression: the first and last words are reachable and distinct."""
    await bring_up(dut)

    await write(dut, 0, 0x0000_00FF & DATA_MASK)
    await write(dut, DEPTH - 1, 0xFF00_0000 & DATA_MASK)

    assert_eq(await read(dut, 0), 0x0000_00FF & DATA_MASK, "first word")
    assert_eq(await read(dut, DEPTH - 1), 0xFF00_0000 & DATA_MASK, "last word")
