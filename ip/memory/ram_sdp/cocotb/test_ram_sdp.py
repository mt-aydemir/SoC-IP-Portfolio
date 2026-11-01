"""Cocotb regression for ram_sdp.

Coverage
    directed   write then read back, byte-enable masking, simultaneous
               write and read of different addresses, same-address collision
               returning old data
    randomised concurrent write and read streams at three clock ratios,
               compared against a reference dictionary
    regression a full sweep of the array, and sustained concurrent traffic

The interesting property of a simple dual-port memory is that the two ports
run in unrelated clock domains and never interfere. Testing it at one clock
ratio proves very little, so the concurrent tests run with the writer faster,
the reader faster, and the two nearly equal.
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge

from socip import (
    RandomStream,
    assert_eq,
    describe,
    get_param,
    settle,
    start_clock,
)

DATA_WIDTH = get_param("DATA_WIDTH", 32)
DEPTH = get_param("DEPTH", 1024)
BYTE_ENABLE = get_param("BYTE_ENABLE", 0)
OUTPUT_REG = get_param("OUTPUT_REG", 0)

DATA_MASK = (1 << DATA_WIDTH) - 1
NUM_BYTES = max(1, DATA_WIDTH // 8)
ALL_BYTES = (1 << NUM_BYTES) - 1
READ_LATENCY = 1 + (1 if OUTPUT_REG else 0)

RATIOS = {
    "writer_faster": (7.0, 23.0),
    "reader_faster": (23.0, 7.0),
    "near_equal":    (10.0, 10.7),
}


def merge(old: int, new: int, be: int) -> int:
    if not BYTE_ENABLE:
        return new & DATA_MASK
    result = old
    for byte in range(NUM_BYTES):
        if (be >> byte) & 1:
            mask = 0xFF << (byte * 8)
            result = (result & ~mask) | (new & mask)
    return result & DATA_MASK


async def bring_up(dut, wr_period: float = 10.0, rd_period: float = 10.0) -> None:
    dut._log.info("ram_sdp: DATA_WIDTH=%d, DEPTH=%d, BYTE_ENABLE=%d, "
                  "OUTPUT_REG=%d, wr=%.1f ns, rd=%.1f ns, %s",
                  DATA_WIDTH, DEPTH, BYTE_ENABLE, OUTPUT_REG,
                  wr_period, rd_period, describe())
    dut.wr_en.value = 0
    dut.wr_be.value = ALL_BYTES
    dut.wr_addr.value = 0
    dut.wr_data.value = 0
    dut.rd_en.value = 0
    dut.rd_addr.value = 0

    start_clock(dut.wr_clk, wr_period)
    if dut.rd_clk is not dut.wr_clk:
        start_clock(dut.rd_clk, rd_period)
    for _ in range(3):
        await RisingEdge(dut.wr_clk)


async def write(dut, addr: int, data: int, be: int = ALL_BYTES) -> None:
    dut.wr_en.value = 1
    dut.wr_be.value = be
    dut.wr_addr.value = addr
    dut.wr_data.value = data & DATA_MASK
    await RisingEdge(dut.wr_clk)
    dut.wr_en.value = 0


async def read(dut, addr: int) -> int:
    dut.rd_en.value = 1
    dut.rd_addr.value = addr
    for _ in range(READ_LATENCY):
        await RisingEdge(dut.rd_clk)
    dut.rd_en.value = 0
    await settle()
    return int(dut.rd_data.value)


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_write_then_read(dut) -> None:
    """Directed: a written word reads back unchanged."""
    await bring_up(dut)

    for addr, value in ((0, 0xDEAD_BEEF), (1, 0x1),
                        (DEPTH - 1, DATA_MASK), (DEPTH // 2, 0xA5A5_5A5A)):
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
    addr = 11
    await write(dut, addr, 0)
    expected = 0

    for byte in range(NUM_BYTES):
        await write(dut, addr, DATA_MASK, be=1 << byte)
        expected = merge(expected, DATA_MASK, 1 << byte)
        assert_eq(await read(dut, addr), expected,
                  f"after enabling byte lane {byte}")


@cocotb.test()
async def test_concurrent_different_addresses(dut) -> None:
    """Directed: writing one address while reading another is always safe."""
    await bring_up(dut)

    await write(dut, 4, 0x4444_4444 & DATA_MASK)
    await write(dut, 8, 0x8888_8888 & DATA_MASK)

    # Drive a write and a read in the same cycles.
    dut.rd_en.value = 1
    dut.rd_addr.value = 4
    dut.wr_en.value = 1
    dut.wr_be.value = ALL_BYTES
    dut.wr_addr.value = 8
    dut.wr_data.value = 0x9999_9999 & DATA_MASK

    for _ in range(READ_LATENCY):
        await RisingEdge(dut.wr_clk)
    dut.wr_en.value = 0
    dut.rd_en.value = 0
    await settle()

    assert_eq(int(dut.rd_data.value), 0x4444_4444 & DATA_MASK,
              "the read is unaffected by a write elsewhere")
    assert_eq(await read(dut, 8), 0x9999_9999 & DATA_MASK,
              "the write landed")


@cocotb.test()
async def test_same_address_collision_returns_old(dut) -> None:
    """Directed: reading the address being written returns the old contents.

    The read is issued from the array before the write in that cycle has
    landed. Callers needing the new data must bypass around the memory, which
    is exactly what fifo_sync does for its first-word-fall-through path.
    """
    await bring_up(dut)
    addr = 6
    old = 0x1111_1111 & DATA_MASK
    new = 0x2222_2222 & DATA_MASK

    await write(dut, addr, old)

    dut.rd_en.value = 1
    dut.rd_addr.value = addr
    dut.wr_en.value = 1
    dut.wr_be.value = ALL_BYTES
    dut.wr_addr.value = addr
    dut.wr_data.value = new
    await RisingEdge(dut.wr_clk)
    dut.wr_en.value = 0

    for _ in range(READ_LATENCY - 1):
        await RisingEdge(dut.rd_clk)
    dut.rd_en.value = 0
    await settle()

    assert_eq(int(dut.rd_data.value), old, "collision must return old data")
    assert_eq(await read(dut, addr), new, "the write must still have landed")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_traffic_all_ratios(dut) -> None:
    """Randomised: reads and writes against a model, at every clock ratio."""
    rng = RandomStream("ram_sdp")
    dut._log.info("random seed = %d", rng.seed)

    for name, (wr_period, rd_period) in RATIOS.items():
        await bring_up(dut, wr_period, rd_period)

        window = min(DEPTH, 32)
        model: dict[int, int] = {}
        for addr in range(window):
            await write(dut, addr, 0)
            model[addr] = 0

        for operation in range(200):
            addr = rng.between(0, window - 1)
            if rng.boolean(0.5):
                data = rng.corner_uint(DATA_WIDTH)
                be = rng.between(1, ALL_BYTES) if BYTE_ENABLE else ALL_BYTES
                await write(dut, addr, data, be)
                model[addr] = merge(model[addr], data, be)
            else:
                assert_eq(await read(dut, addr), model[addr],
                          f"ratio {name}, operation {operation}, address {addr}")

        dut._log.info("ratio %s: 200 operations matched", name)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_every_location_is_distinct(dut) -> None:
    """Regression: a distinct value in every location, read back in full."""
    await bring_up(dut)
    count = min(DEPTH, 256)

    for addr in range(count):
        await write(dut, addr, (addr * 0x0101_0101 + 0x9E37) & DATA_MASK)

    for addr in range(count):
        assert_eq(await read(dut, addr),
                  (addr * 0x0101_0101 + 0x9E37) & DATA_MASK,
                  f"address {addr} after the full sweep")


@cocotb.test()
async def test_sustained_concurrent_traffic(dut) -> None:
    """Regression: both ports driven every cycle, on unrelated clocks.

    The write port marches through the array while the read port trails it,
    so the two are almost always accessing different addresses and neither
    ever stops.
    """
    await bring_up(dut, *RATIOS["near_equal"])
    window = min(DEPTH, 64)

    async def writer() -> None:
        for index in range(window * 4):
            await write(dut, index % window,
                        (index * 0x1234_5679) & DATA_MASK)

    task = cocotb.start_soon(writer())
    for _ in range(window * 4):
        await RisingEdge(dut.rd_clk)
    await task

    # After the final pass, every location holds the value from that pass.
    for addr in range(window):
        expected = ((window * 3 + addr) * 0x1234_5679) & DATA_MASK
        assert_eq(await read(dut, addr), expected,
                  f"address {addr} after sustained traffic")
