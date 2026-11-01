"""Cocotb regression for i2c_master.

Coverage
    directed   the reset state; a register write and a register read with a
               repeated START against an EEPROM-style slave; an address that
               nobody acknowledges; the last read byte NACKed; clock
               stretching by the slave; arbitration lost to another master
    randomised random write and read transactions, lengths, register
               addresses, data and SCL rates against the slave's memory
    regression SDA never changes while SCL is high except for START and STOP;
               SCL low and high times are never shorter than 2 * clk_div; a
               stretched clock lengthens the high time instead of shortening
               it

The bus is modelled as open drain: each line is low if the master or the
slave pulls it, and the resolved level is fed back to scl_i / sda_i. The
slave is written from the I2C protocol (address, register pointer,
auto-increment), not from the RTL, and the bus monitor checks the line timing
on every clock.
"""
from __future__ import annotations

import cocotb
from cocotb.triggers import NextTimeStep, ReadOnly, RisingEdge

from socip import ClockDomain, RandomStream, assert_eq, describe, get_param

DIV_WIDTH = get_param("DIV_WIDTH", 16)
SYNC_STAGES = get_param("SYNC_STAGES", 2)

CLK_PERIOD_NS = 10.0
START, STOP, WRITE, READ = range(4)
SLAVE_ADDR = 0x50


class Bus:
    """Open-drain resolution, an EEPROM-style slave and a timing monitor."""

    def __init__(self, dut, div: int) -> None:
        self.dut = dut
        self.div = div
        self.memory = [0] * 256
        self.stretch = 0              # cycles to hold SCL low after each ACK
        self.disturb = False          # another master pulling SDA low
        self.errors: list[str] = []
        self.conditions: list[str] = []
        self._scl_hold = 0
        self._sda_low = False
        # slave protocol state
        self._state = "idle"
        self._bits = 0
        self._shift = 0
        self._first_byte = True
        self._pointer = 0
        self._pointer_set = False
        self._task = cocotb.start_soon(self._run())

    def stop(self) -> None:
        self._task.kill()

    # --- slave protocol, written from the I2C specification ---------------
    def _on_start(self) -> None:
        self.conditions.append("S")
        self._state = "rx"
        self._bits = 0
        self._shift = 0
        self._first_byte = True
        self._sda_low = False

    def _on_stop(self) -> None:
        self.conditions.append("P")
        self._state = "idle"
        self._sda_low = False

    def _on_rise(self, sda: int) -> None:
        if self._state == "rx":
            self._shift = ((self._shift << 1) | sda) & 0xFF
            self._bits += 1
        elif self._state == "tx":
            self._bits += 1
        elif self._state == "ack_in":
            self._master_nack = sda

    def _on_fall(self) -> None:
        if self._state == "rx" and self._bits == 8:
            byte = self._shift
            if self._first_byte:
                self._addressed = (byte >> 1) == SLAVE_ADDR
                self._reading = byte & 1
            self._sda_low = self._first_byte and self._addressed or \
                (not self._first_byte)
            self._state = "ack_out"
            self._byte = byte
            if self.stretch:
                self._scl_hold = self.stretch
        elif self._state == "ack_out":
            self._sda_low = False
            if self._first_byte:
                self._first_byte = False
                if not self._addressed:
                    self._state = "idle"
                elif self._reading:
                    self._load_tx()
                else:
                    self._state = "rx"
                    self._bits = 0
                    self._pointer_set = False
            else:
                if not self._pointer_set:
                    self._pointer = self._byte
                    self._pointer_set = True
                else:
                    self.memory[self._pointer] = self._byte
                    self._pointer = (self._pointer + 1) & 0xFF
                self._state = "rx"
                self._bits = 0
        elif self._state == "tx":
            if self._bits == 8:
                self._sda_low = False
                self._state = "ack_in"
            else:
                self._sda_low = not ((self._tx >> (7 - self._bits)) & 1)
        elif self._state == "ack_in":
            if self._master_nack:
                self._sda_low = False
                self._state = "idle"
            else:
                self._load_tx()

    def _load_tx(self) -> None:
        self._tx = self.memory[self._pointer]
        self._pointer = (self._pointer + 1) & 0xFF
        self._state = "tx"
        self._bits = 0
        self._sda_low = not ((self._tx >> 7) & 1)

    # --- bus resolution and timing monitor --------------------------------
    async def _run(self) -> None:
        dut = self.dut
        scl_prev = sda_prev = 1
        last_scl_change = 0
        cycle = 0
        dut.scl_i.value = 1
        dut.sda_i.value = 1
        while True:
            await RisingEdge(dut.clk)
            await ReadOnly()
            cycle += 1
            scl_oe = int(dut.scl_oe.value)
            sda_oe = int(dut.sda_oe.value)

            scl = int(not (scl_oe or self._scl_hold > 0))
            sda = int(not (sda_oe or self._sda_low or self.disturb))

            if scl != scl_prev:
                width = cycle - last_scl_change
                # The master drives each SCL level for two phases. Either can
                # be longer (stretching, synchroniser), never shorter.
                if width < 2 * self.div and cycle > 4:
                    self.errors.append(f"cycle {cycle}: SCL "
                                       f"{'high' if scl_prev else 'low'} for "
                                       f"{width} cycles < {2 * self.div}")
                last_scl_change = cycle

            if scl_prev == 1 and scl == 1 and sda != sda_prev:
                if sda == 0:
                    self._on_start()
                else:
                    self._on_stop()
            elif scl_prev == 0 and scl == 1:
                self._on_rise(sda)
            elif scl_prev == 1 and scl == 0:
                self._on_fall()

            if self._scl_hold > 0:
                self._scl_hold -= 1

            scl_prev, sda_prev = scl, sda
            # Re-resolve after the slave reacted; the master sees it next edge.
            scl_line = int(not (scl_oe or self._scl_hold > 0))
            sda_line = int(not (sda_oe or self._sda_low or self.disturb))
            await NextTimeStep()
            dut.scl_i.value = scl_line
            dut.sda_i.value = sda_line


class Host:
    """Issues commands and collects one response per command."""

    def __init__(self, dut) -> None:
        self.dut = dut

    async def command(self, cmd: int, data: int = 0, nack: int = 0,
                      timeout: int = 200_000,
                      allow_arb_loss: bool = False) -> tuple[int, int, int]:
        """One command, one response.

        On a single-master bus no command may lose arbitration, so that is
        checked on every response unless the test is provoking a loss.
        """
        dut = self.dut
        dut.s_cmd.value = cmd
        dut.s_data.value = data & 0xFF
        dut.s_nack.value = nack
        dut.s_valid.value = 1
        while True:
            await ReadOnly()
            if int(dut.s_ready.value):
                break
            await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)
        dut.s_valid.value = 0
        for _ in range(timeout):
            await RisingEdge(dut.clk)
            await ReadOnly()
            if int(dut.m_valid.value):
                result = (int(dut.m_data.value), int(dut.m_nack.value),
                          int(dut.m_arb_lost.value))
                await NextTimeStep()
                if not allow_arb_loss:
                    assert_eq(result[2], 0, f"arbitration lost on command {cmd}")
                return result
        raise AssertionError(f"no response to command {cmd}")

    async def write_regs(self, reg: int, data: list[int]) -> list[int]:
        """START, address+W, register, data..., STOP; returns the ACK bits."""
        acks = []
        await self.command(START)
        acks.append((await self.command(WRITE, SLAVE_ADDR << 1))[1])
        acks.append((await self.command(WRITE, reg))[1])
        for byte in data:
            acks.append((await self.command(WRITE, byte))[1])
        await self.command(STOP)
        return acks

    async def read_regs(self, reg: int, count: int) -> list[int]:
        """START, address+W, register, repeated START, address+R, reads, STOP."""
        await self.command(START)
        assert_eq((await self.command(WRITE, SLAVE_ADDR << 1))[1], 0, "addr+W ack")
        assert_eq((await self.command(WRITE, reg))[1], 0, "register ack")
        await self.command(START)
        assert_eq((await self.command(WRITE, (SLAVE_ADDR << 1) | 1))[1], 0,
                  "addr+R ack")
        data = []
        for i in range(count):
            data.append((await self.command(READ, nack=int(i == count - 1)))[0])
        await self.command(STOP)
        return data


async def setup(dut, div: int) -> tuple[Host, Bus, ClockDomain]:
    dut._log.info("i2c_master: DIV_WIDTH=%d SYNC_STAGES=%d clk_div=%d, %s",
                  DIV_WIDTH, SYNC_STAGES, div, describe())
    dut.clk_div.value = div
    dut.s_valid.value = 0
    dut.s_cmd.value = 0
    dut.s_data.value = 0
    dut.s_nack.value = 0
    dut.scl_i.value = 1
    dut.sda_i.value = 1
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    await domain.reset()
    return Host(dut), Bus(dut, div), domain


def check_bus(bus: Bus) -> None:
    assert not bus.errors, "; ".join(bus.errors[:3])


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: both lines released, ready, not busy."""
    await setup(dut, 4)
    await ReadOnly()
    assert_eq(int(dut.scl_oe.value), 0, "SCL released")
    assert_eq(int(dut.sda_oe.value), 0, "SDA released")
    assert_eq(int(dut.s_ready.value), 1, "ready")
    assert_eq(int(dut.busy.value), 0, "not busy")


@cocotb.test()
async def test_write_then_read(dut) -> None:
    """Directed: register write, then read back with a repeated START."""
    host, bus, _ = await setup(dut, 4)
    data = [0x00, 0xFF, 0xA5, 0x5A, 0x01, 0x80]
    acks = await host.write_regs(0x10, data)
    assert acks == [0] * (2 + len(data)), f"every byte acknowledged: {acks}"
    assert bus.memory[0x10:0x10 + len(data)] == data, "slave memory"
    assert_eq(await host.read_regs(0x10, len(data)) == data, 1, "read back")
    assert bus.conditions == ["S", "P", "S", "S", "P"], bus.conditions
    check_bus(bus)


@cocotb.test()
async def test_address_nack(dut) -> None:
    """Directed: an address nobody owns is NACKed."""
    host, bus, _ = await setup(dut, 3)
    await host.command(START)
    _data, nack, arb = await host.command(WRITE, 0x23 << 1)
    await host.command(STOP)
    assert_eq(nack, 1, "address NACKed")
    assert_eq(arb, 0, "no arbitration loss")
    check_bus(bus)


@cocotb.test()
async def test_clock_stretching(dut) -> None:
    """Regression: a slave stretching every ACK slows the bus, nothing else."""
    host, bus, _ = await setup(dut, 3)
    bus.stretch = 60
    data = [0x12, 0x34, 0x56]
    assert await host.write_regs(0x40, data) == [0] * 5, "acks while stretched"
    assert_eq(await host.read_regs(0x40, 3) == data, 1, "read while stretched")
    check_bus(bus)


@cocotb.test()
async def test_minimum_divider(dut) -> None:
    """Directed: the fastest legal setting still transfers correctly.

    The floor is 2 * clk_div >= SYNC_STAGES + 1: SDA released for STOP has to
    come back through the synchroniser before it is checked.
    """
    host, bus, _ = await setup(dut, (SYNC_STAGES + 2) // 2)
    data = [0xC3, 0x3C]
    assert await host.write_regs(0x02, data) == [0] * 4, "acks"
    assert_eq(await host.read_regs(0x02, 2) == data, 1, "read back")
    check_bus(bus)


@cocotb.test()
async def test_arbitration_lost(dut) -> None:
    """Directed: another master driving SDA low wins; the lines are released."""
    host, bus, _ = await setup(dut, 4)
    await host.command(START)
    bus.disturb = True                # the other master sends 0x00
    _data, _nack, arb = await host.command(WRITE, 0xFF, allow_arb_loss=True)
    assert_eq(arb, 1, "arbitration lost on the first 1 bit")
    for _ in range(3):
        await RisingEdge(dut.clk)
    await ReadOnly()
    assert_eq(int(dut.scl_oe.value), 0, "SCL released after the loss")
    assert_eq(int(dut.sda_oe.value), 0, "SDA released after the loss")
    assert_eq(int(dut.s_ready.value), 1, "ready for the next command")


# ---------------------------------------------------------------------------
# Randomised
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_transactions(dut) -> None:
    """Randomised: writes and reads of random lengths at random rates."""
    rng = RandomStream("i2c_random")
    dut._log.info("random seed = %d", rng.seed)
    host, bus, _ = await setup(dut, rng.between((SYNC_STAGES + 2) // 2, 6))
    shadow = [0] * 256
    for _ in range(12):
        reg = rng.between(0, 255)
        length = rng.between(1, 4)
        bus.stretch = rng.choice([0, 0, rng.between(1, 30)])
        if rng.boolean(0.5):
            data = [rng.uint(8) for _ in range(length)]
            assert await host.write_regs(reg, data) == [0] * (2 + length)
            for i, byte in enumerate(data):
                shadow[(reg + i) & 0xFF] = byte
        else:
            got = await host.read_regs(reg, length)
            want = [shadow[(reg + i) & 0xFF] for i in range(length)]
            assert got == want, f"read {reg:#x}: got {got}, expected {want}"
    check_bus(bus)
