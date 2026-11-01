"""Cocotb regression for register_file.

Coverage
    directed   reset state, write then read, register zero, read-during-write
               bypass, independence of the read ports
    randomised random writes and reads against a reference dictionary, with
               every read port checked on every cycle
    regression a full sweep writing and reading every register, and a long
               randomised run

The reference model is a plain Python dict, which is the point of testing in
cocotb: the model is obviously correct, so a mismatch is always the design.
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
NUM_REGS = get_param("NUM_REGS", 32)
NUM_READ_PORTS = get_param("NUM_READ_PORTS", 2)
ZERO_REGISTER = get_param("ZERO_REGISTER", 1)
BYPASS_WRITE = get_param("BYPASS_WRITE", 1)

CLK_PERIOD_NS = 10.0
DATA_MASK = (1 << DATA_WIDTH) - 1


class Model:
    """Reference model: the register file as a dictionary."""

    def __init__(self) -> None:
        self.regs = {index: 0 for index in range(NUM_REGS)}

    def write(self, addr: int, data: int) -> None:
        if ZERO_REGISTER and addr == 0:
            return
        self.regs[addr] = data & DATA_MASK

    def read(self, addr: int, write_addr: int | None = None,
             write_data: int | None = None) -> int:
        """Read *addr*, applying the bypass if a write is happening this cycle."""
        if ZERO_REGISTER and addr == 0:
            return 0
        if BYPASS_WRITE and write_addr is not None and write_addr == addr:
            if not (ZERO_REGISTER and write_addr == 0):
                return write_data & DATA_MASK
        return self.regs[addr]


async def bring_up(dut) -> ClockDomain:
    """Reset the register file and leave every port idle."""
    dut._log.info("register_file: DATA_WIDTH=%d, NUM_REGS=%d, PORTS=%d, "
                  "ZERO_REGISTER=%d, BYPASS_WRITE=%d, %s",
                  DATA_WIDTH, NUM_REGS, NUM_READ_PORTS,
                  ZERO_REGISTER, BYPASS_WRITE, describe())

    dut.write_en.value = 0
    dut.write_addr.value = 0
    dut.write_data.value = 0
    dut.read_addr.value = 0

    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    await domain.reset()
    return domain


def set_read_addrs(dut, addrs: list[int]) -> None:
    """Drive the packed read address bus."""
    addr_width = max(1, (NUM_REGS - 1).bit_length())
    packed = 0
    for port, addr in enumerate(addrs):
        packed |= (addr & ((1 << addr_width) - 1)) << (port * addr_width)
    dut.read_addr.value = packed


def get_read_data(dut) -> list[int]:
    """Unpack the read data bus into one value per port."""
    packed = int(dut.read_data.value)
    return [(packed >> (port * DATA_WIDTH)) & DATA_MASK
            for port in range(NUM_READ_PORTS)]


async def write(dut, domain: ClockDomain, addr: int, data: int) -> None:
    dut.write_en.value = 1
    dut.write_addr.value = addr
    dut.write_data.value = data & DATA_MASK
    await RisingEdge(dut.clk)
    dut.write_en.value = 0


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_clears_every_register(dut) -> None:
    """Directed: every register reads zero after reset."""
    await bring_up(dut)

    for addr in range(NUM_REGS):
        set_read_addrs(dut, [addr] * NUM_READ_PORTS)
        await settle()
        for port, value in enumerate(get_read_data(dut)):
            assert_eq(value, 0, f"register {addr} on port {port} after reset")


@cocotb.test()
async def test_write_then_read(dut) -> None:
    """Directed: a written value is visible on the following cycle."""
    domain = await bring_up(dut)
    model = Model()

    first = 1 if ZERO_REGISTER else 0
    for addr in range(first, min(NUM_REGS, first + 8)):
        value = (0xA5A5_0000 + addr) & DATA_MASK
        await write(dut, domain, addr, value)
        model.write(addr, value)

        set_read_addrs(dut, [addr] * NUM_READ_PORTS)
        await settle()
        for port, actual in enumerate(get_read_data(dut)):
            assert_eq(actual, model.read(addr),
                      f"register {addr} on port {port}")


@cocotb.test()
async def test_register_zero(dut) -> None:
    """Directed: register 0 reads zero and ignores writes, when configured."""
    domain = await bring_up(dut)

    await write(dut, domain, 0, DATA_MASK)
    set_read_addrs(dut, [0] * NUM_READ_PORTS)
    await settle()

    expected = 0 if ZERO_REGISTER else DATA_MASK
    for port, actual in enumerate(get_read_data(dut)):
        assert_eq(actual, expected, f"register 0 on port {port}")


@cocotb.test()
async def test_read_during_write_bypass(dut) -> None:
    """Directed: a read of the register being written returns the new data.

    Without the bypass a processor datapath needs its own forwarding path for
    the write-back stage, so this is the behaviour that decides whether the
    block is usable as a register file at all.
    """
    domain = await bring_up(dut)

    addr = 1 if ZERO_REGISTER else 0
    old = 0x1111_1111 & DATA_MASK
    new = 0x2222_2222 & DATA_MASK

    await write(dut, domain, addr, old)

    # Present the write and read the same address in the same cycle.
    set_read_addrs(dut, [addr] * NUM_READ_PORTS)
    dut.write_en.value = 1
    dut.write_addr.value = addr
    dut.write_data.value = new
    await settle()

    expected = new if BYPASS_WRITE else old
    for port, actual in enumerate(get_read_data(dut)):
        assert_eq(actual, expected,
                  f"read-during-write on port {port} "
                  f"(BYPASS_WRITE={BYPASS_WRITE})")

    await RisingEdge(dut.clk)
    dut.write_en.value = 0
    await domain.edge()


@cocotb.test()
async def test_read_ports_are_independent(dut) -> None:
    """Directed: each port reads its own address."""
    if NUM_READ_PORTS < 2:
        dut._log.info("only one read port; independence is trivial")
        return

    domain = await bring_up(dut)
    first = 1 if ZERO_REGISTER else 0
    addrs = [(first + port) % NUM_REGS for port in range(NUM_READ_PORTS)]

    for port, addr in enumerate(addrs):
        if ZERO_REGISTER and addr == 0:
            continue
        await write(dut, domain, addr, (0xC0DE_0000 + port) & DATA_MASK)

    set_read_addrs(dut, addrs)
    await settle()

    for port, actual in enumerate(get_read_data(dut)):
        addr = addrs[port]
        expected = 0 if (ZERO_REGISTER and addr == 0) \
            else (0xC0DE_0000 + port) & DATA_MASK
        assert_eq(actual, expected, f"port {port} reading register {addr}")


# ---------------------------------------------------------------------------
# Randomised tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_traffic(dut) -> None:
    """Randomised: random writes with every read port checked every cycle."""
    rng = RandomStream("register_file")
    dut._log.info("random seed = %d", rng.seed)

    domain = await bring_up(dut)
    model = Model()

    for cycle in range(1500):
        do_write = rng.boolean(0.6)
        write_addr = rng.between(0, NUM_REGS - 1)
        write_data = rng.corner_uint(DATA_WIDTH)
        read_addrs = [rng.between(0, NUM_REGS - 1)
                      for _ in range(NUM_READ_PORTS)]

        dut.write_en.value = int(do_write)
        dut.write_addr.value = write_addr
        dut.write_data.value = write_data
        set_read_addrs(dut, read_addrs)
        await settle()

        for port, actual in enumerate(get_read_data(dut)):
            expected = model.read(
                read_addrs[port],
                write_addr if do_write else None,
                write_data if do_write else None)
            assert_eq(actual, expected,
                      f"cycle {cycle}, port {port}, register {read_addrs[port]}")

        await RisingEdge(dut.clk)
        if do_write:
            model.write(write_addr, write_data)

    dut.write_en.value = 0
    await domain.edge()


# ---------------------------------------------------------------------------
# Regression tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_every_register_holds_its_own_value(dut) -> None:
    """Regression: write a distinct value to every register, then read them back.

    A decoder that aliases two addresses, or a write enable that leaks, shows
    up here and nowhere else.
    """
    domain = await bring_up(dut)
    model = Model()

    for addr in range(NUM_REGS):
        value = (addr * 0x0101_0101 + 0x1234) & DATA_MASK
        await write(dut, domain, addr, value)
        model.write(addr, value)

    dut.write_en.value = 0
    for addr in range(NUM_REGS):
        set_read_addrs(dut, [addr] * NUM_READ_PORTS)
        await settle()
        for port, actual in enumerate(get_read_data(dut)):
            assert_eq(actual, model.read(addr),
                      f"register {addr} on port {port} after the full sweep")

    await domain.edge()
