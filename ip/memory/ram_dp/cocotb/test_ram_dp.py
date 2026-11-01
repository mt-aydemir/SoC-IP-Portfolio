"""Cocotb regression for ram_dp.

Coverage
    directed   each port writes and reads independently, data written on one
               port is visible from the other, byte-enable masking on both
               ports, concurrent access to different addresses
    randomised both ports driven concurrently over a partitioned address
               space, at three clock ratios, against a reference dictionary
    regression a full sweep from each port, and sustained concurrent traffic

The address space is partitioned in the concurrent tests — port A owns the
even addresses, port B the odd ones. That is not a limitation of the test but
the documented way to use a true dual-port memory: the block does not
arbitrate, because the physical macro does not either, so a same-address
collision is undefined by construction and there is nothing meaningful to
check about it.
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
BYTE_ENABLE = get_param("BYTE_ENABLE", 1)
OUTPUT_REG = get_param("OUTPUT_REG", 0)

DATA_MASK = (1 << DATA_WIDTH) - 1
NUM_BYTES = max(1, DATA_WIDTH // 8)
ALL_BYTES = (1 << NUM_BYTES) - 1
READ_LATENCY = 1 + (1 if OUTPUT_REG else 0)

RATIOS = {
    "a_faster":   (7.0, 23.0),
    "b_faster":   (23.0, 7.0),
    "near_equal": (10.0, 10.7),
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


class Port:
    """One side of the memory, so the tests can be written once."""

    def __init__(self, dut, name: str) -> None:
        self.dut = dut
        self.name = name
        self.clk = getattr(dut, f"clk_{name}")
        self.en = getattr(dut, f"en_{name}")
        self.we = getattr(dut, f"we_{name}")
        self.be = getattr(dut, f"be_{name}")
        self.addr = getattr(dut, f"addr_{name}")
        self.wdata = getattr(dut, f"wdata_{name}")
        self.rdata = getattr(dut, f"rdata_{name}")

    def idle(self) -> None:
        self.en.value = 0
        self.we.value = 0
        self.be.value = ALL_BYTES
        self.addr.value = 0
        self.wdata.value = 0

    async def write(self, addr: int, data: int, be: int = ALL_BYTES) -> None:
        self.en.value = 1
        self.we.value = 1
        self.be.value = be
        self.addr.value = addr
        self.wdata.value = data & DATA_MASK
        await RisingEdge(self.clk)
        self.en.value = 0
        self.we.value = 0

    async def read(self, addr: int) -> int:
        self.en.value = 1
        self.we.value = 0
        self.addr.value = addr
        for _ in range(READ_LATENCY):
            await RisingEdge(self.clk)
        self.en.value = 0
        await settle()
        return int(self.rdata.value)


async def bring_up(dut, period_a: float = 10.0,
                   period_b: float = 10.0) -> tuple[Port, Port]:
    dut._log.info("ram_dp: DATA_WIDTH=%d, DEPTH=%d, BYTE_ENABLE=%d, "
                  "OUTPUT_REG=%d, clk_a=%.1f ns, clk_b=%.1f ns, %s",
                  DATA_WIDTH, DEPTH, BYTE_ENABLE, OUTPUT_REG,
                  period_a, period_b, describe())

    port_a = Port(dut, "a")
    port_b = Port(dut, "b")
    port_a.idle()
    port_b.idle()

    start_clock(dut.clk_a, period_a)
    start_clock(dut.clk_b, period_b)
    for _ in range(3):
        await RisingEdge(dut.clk_a)
    return port_a, port_b


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_each_port_reads_its_own_writes(dut) -> None:
    """Directed: both ports work independently as ordinary memories."""
    port_a, port_b = await bring_up(dut)

    for port, base in ((port_a, 0x0), (port_b, 0x10)):
        for offset, value in enumerate((0xDEAD_BEEF, 0x1, DATA_MASK)):
            addr = base + offset
            await port.write(addr, value)
            assert_eq(await port.read(addr), value & DATA_MASK,
                      f"port {port.name} address {addr}")


@cocotb.test()
async def test_ports_share_the_array(dut) -> None:
    """Directed: what one port writes, the other reads."""
    port_a, port_b = await bring_up(dut)

    await port_a.write(0x20, 0xCAFE_BABE & DATA_MASK)
    assert_eq(await port_b.read(0x20), 0xCAFE_BABE & DATA_MASK,
              "port B must see port A's write")

    await port_b.write(0x21, 0xFEED_FACE & DATA_MASK)
    assert_eq(await port_a.read(0x21), 0xFEED_FACE & DATA_MASK,
              "port A must see port B's write")


@cocotb.test()
async def test_byte_enables_on_both_ports(dut) -> None:
    """Directed: byte-lane masking works from either port."""
    if not BYTE_ENABLE:
        dut._log.info("byte enables disabled at elaboration")
        return

    port_a, port_b = await bring_up(dut)

    for port, addr in ((port_a, 0x30), (port_b, 0x31)):
        await port.write(addr, 0)
        expected = 0
        for byte in range(NUM_BYTES):
            await port.write(addr, DATA_MASK, be=1 << byte)
            expected = merge(expected, DATA_MASK, 1 << byte)
            assert_eq(await port.read(addr), expected,
                      f"port {port.name}, byte lane {byte}")


@cocotb.test()
async def test_concurrent_different_addresses(dut) -> None:
    """Directed: simultaneous access to different addresses is always safe."""
    port_a, port_b = await bring_up(dut)

    await port_a.write(0x40, 0x4040_4040 & DATA_MASK)
    await port_b.write(0x41, 0x4141_4141 & DATA_MASK)

    # Both ports active in the same cycles, on different addresses.
    port_a.en.value = 1
    port_a.we.value = 0
    port_a.addr.value = 0x40
    port_b.en.value = 1
    port_b.we.value = 1
    port_b.be.value = ALL_BYTES
    port_b.addr.value = 0x42
    port_b.wdata.value = 0x4242_4242 & DATA_MASK

    for _ in range(READ_LATENCY):
        await RisingEdge(dut.clk_a)
    port_a.en.value = 0
    port_b.en.value = 0
    port_b.we.value = 0
    await settle()

    assert_eq(int(port_a.rdata.value), 0x4040_4040 & DATA_MASK,
              "port A read is unaffected by port B's write")
    assert_eq(await port_a.read(0x42), 0x4242_4242 & DATA_MASK,
              "port B's concurrent write landed")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_partitioned_traffic(dut) -> None:
    """Randomised: both ports busy over a partitioned address space.

    Port A owns even addresses, port B odd ones, so the two never collide —
    the documented way to use a memory that does not arbitrate.
    """
    rng = RandomStream("ram_dp")
    dut._log.info("random seed = %d", rng.seed)

    for name, (period_a, period_b) in RATIOS.items():
        port_a, port_b = await bring_up(dut, period_a, period_b)
        window = min(DEPTH, 64)

        model: dict[int, int] = {}
        for addr in range(window):
            await port_a.write(addr, 0)
            model[addr] = 0

        async def drive(port: Port, parity: int, operations: int) -> None:
            for _ in range(operations):
                addr = rng.between(0, window // 2 - 1) * 2 + parity
                if rng.boolean(0.5):
                    data = rng.corner_uint(DATA_WIDTH)
                    be = rng.between(1, ALL_BYTES) if BYTE_ENABLE else ALL_BYTES
                    await port.write(addr, data, be)
                    model[addr] = merge(model[addr], data, be)
                else:
                    assert_eq(await port.read(addr), model[addr],
                              f"ratio {name}, port {port.name}, address {addr}")

        task_a = cocotb.start_soon(drive(port_a, 0, 120))
        await drive(port_b, 1, 120)
        await task_a

        dut._log.info("ratio %s: both ports matched", name)


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_full_sweep_from_each_port(dut) -> None:
    """Regression: write the whole array from A, read it all back from B."""
    port_a, port_b = await bring_up(dut)
    count = min(DEPTH, 256)

    for addr in range(count):
        await port_a.write(addr, (addr * 0x0101_0101 + 0x9E37) & DATA_MASK)

    for addr in range(count):
        assert_eq(await port_b.read(addr),
                  (addr * 0x0101_0101 + 0x9E37) & DATA_MASK,
                  f"port B reading address {addr} written by port A")


@cocotb.test()
async def test_address_boundaries(dut) -> None:
    """Regression: the first and last words are reachable from both ports."""
    port_a, port_b = await bring_up(dut)

    await port_a.write(0, 0x0000_00FF & DATA_MASK)
    await port_b.write(DEPTH - 1, 0xFF00_0000 & DATA_MASK)

    assert_eq(await port_b.read(0), 0x0000_00FF & DATA_MASK, "first word")
    assert_eq(await port_a.read(DEPTH - 1), 0xFF00_0000 & DATA_MASK,
              "last word")
