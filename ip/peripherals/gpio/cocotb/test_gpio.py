"""Cocotb regression for gpio.

Coverage
    directed   the reset state, every register's read and write behaviour,
               atomic set and clear, the input synchroniser latency, rising
               and falling edge interrupts, write-1-to-clear, and pins that
               are high when reset is released
    randomised register writes and pin activity every cycle against a
               cycle-accurate reference model
    regression an edge arriving in the same cycle as the clear of its status
               bit is kept, not lost; outputs keep their value when turned
               into inputs and back

The reference model is written from the register map in the RTL header, not
from the RTL: it keeps its own synchroniser pipeline, steps once per edge with
the inputs applied before it, and is compared against every output after it.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import cocotb
from cocotb.triggers import NextTimeStep, ReadOnly, RisingEdge

from socip import ClockDomain, RandomStream, assert_eq, describe, get_param

WIDTH = get_param("WIDTH", 8)
SYNC_STAGES = get_param("SYNC_STAGES", 2)

CLK_PERIOD_NS = 10.0
MASK = (1 << WIDTH) - 1

OUT, DIR, IN, OUT_SET, OUT_CLR, RISE_EN, FALL_EN, STATUS = range(8)
NAMES = ["OUT", "DIR", "IN", "OUT_SET", "OUT_CLR", "RISE_EN", "FALL_EN",
         "STATUS"]


@dataclass
class Model:
    """Cycle-accurate reference for the GPIO port."""

    sync: list[int] = field(default_factory=lambda: [0] * SYNC_STAGES)
    prev: int = 0
    out: int = 0
    dir: int = 0
    rise_en: int = 0
    fall_en: int = 0
    status: int = 0

    def reset(self) -> None:
        self.sync = [0] * SYNC_STAGES
        self.prev = 0
        self.out = self.dir = self.rise_en = self.fall_en = self.status = 0

    @property
    def pin_value(self) -> int:
        return self.sync[-1]

    def read(self, addr: int) -> int:
        return {
            OUT: self.out,
            DIR: self.dir,
            IN: self.pin_value,
            RISE_EN: self.rise_en,
            FALL_EN: self.fall_en,
            STATUS: self.status,
        }.get(addr, 0)

    def step(self, addr: int, wr_en: int, wr_data: int, pin_in: int) -> None:
        """Advance one edge with the inputs applied before it."""
        current = self.pin_value
        rise = current & ~self.prev & MASK
        fall = ~current & self.prev & MASK
        clear = wr_data if (wr_en and addr == STATUS) else 0

        self.status = ((self.status & ~clear)
                       | (rise & self.rise_en)
                       | (fall & self.fall_en)) & MASK

        if wr_en:
            if addr == OUT:
                self.out = wr_data
            elif addr == DIR:
                self.dir = wr_data
            elif addr == OUT_SET:
                self.out |= wr_data
            elif addr == OUT_CLR:
                self.out &= ~wr_data & MASK
            elif addr == RISE_EN:
                self.rise_en = wr_data
            elif addr == FALL_EN:
                self.fall_en = wr_data

        self.prev = current
        self.sync = [pin_in & MASK] + self.sync[:-1]


class Driver:
    """Drives one cycle at a time and checks every output after each edge."""

    def __init__(self, dut, domain: ClockDomain) -> None:
        self.dut = dut
        self.domain = domain
        self.model = Model()
        self.pins = 0
        self.addr = 0

    def idle(self) -> None:
        self.dut.addr.value = 0
        self.dut.wr_en.value = 0
        self.dut.wr_data.value = 0
        self.dut.pin_in.value = self.pins

    async def reset(self) -> None:
        self.idle()
        await self.domain.reset()
        self.model.reset()
        # The reset helper returns on the first edge after release, and that
        # edge has already clocked the pins into the synchroniser's first
        # stage.
        self.model.sync = [self.pins] + [0] * (SYNC_STAGES - 1)
        await self.step()

    async def step(self, addr: int | None = None, wr_en: int = 0,
                   wr_data: int = 0, pins: int | None = None,
                   label: str = "") -> None:
        if addr is not None:
            self.addr = addr
        if pins is not None:
            self.pins = pins & MASK
        self.dut.addr.value = self.addr
        self.dut.wr_en.value = wr_en
        self.dut.wr_data.value = wr_data & MASK
        self.dut.pin_in.value = self.pins

        await RisingEdge(self.dut.clk)
        self.model.step(self.addr, wr_en, wr_data & MASK, self.pins)
        await self.check(label or f"after {NAMES[self.addr]} wr_en={wr_en}")

    async def check(self, label: str) -> None:
        await ReadOnly()
        rd = int(self.dut.rd_data.value)
        pin_out = int(self.dut.pin_out.value)
        pin_oe = int(self.dut.pin_oe.value)
        irq = int(self.dut.irq.value)
        await NextTimeStep()

        assert_eq(rd, self.model.read(self.addr),
                  f"rd_data ({NAMES[self.addr]}) {label}")
        assert_eq(pin_out, self.model.out, f"pin_out {label}")
        assert_eq(pin_oe, self.model.dir, f"pin_oe {label}")
        assert_eq(irq, int(self.model.status != 0), f"irq {label}")

    async def write(self, addr: int, value: int) -> None:
        await self.step(addr, 1, value, label=f"write {NAMES[addr]}")

    async def read(self, addr: int) -> int:
        await self.step(addr, 0, 0, label=f"read {NAMES[addr]}")
        return self.model.read(addr)

    async def hold(self, cycles: int, pins: int | None = None) -> None:
        for _ in range(cycles):
            await self.step(pins=pins)


async def setup(dut, pins: int = 0) -> Driver:
    dut._log.info("gpio: WIDTH=%d SYNC_STAGES=%d, %s",
                  WIDTH, SYNC_STAGES, describe())
    domain = ClockDomain(dut.clk, dut.rst_n, CLK_PERIOD_NS, "clk").start()
    driver = Driver(dut, domain)
    driver.pins = pins & MASK
    await driver.reset()
    return driver


# ---------------------------------------------------------------------------
# Directed tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_reset_state(dut) -> None:
    """Directed: every pin an input, every register clear, irq low."""
    driver = await setup(dut)
    for addr in range(8):
        assert_eq(await driver.read(addr), 0, f"{NAMES[addr]} after reset")


@cocotb.test()
async def test_register_readback(dut) -> None:
    """Directed: the read-write registers hold what was written."""
    driver = await setup(dut)
    patterns = [MASK, 0, 0x5A5A5A5A & MASK, 0xA5A5A5A5 & MASK, 1,
                1 << (WIDTH - 1)]
    for addr in (OUT, DIR, RISE_EN, FALL_EN):
        for value in patterns:
            await driver.write(addr, value)
            assert_eq(await driver.read(addr), value, f"{NAMES[addr]} readback")


@cocotb.test()
async def test_write_only_registers_read_zero(dut) -> None:
    """Directed: OUT_SET and OUT_CLR read as zero, and IN ignores writes."""
    driver = await setup(dut)
    await driver.write(OUT, MASK)
    for addr in (OUT_SET, OUT_CLR):
        assert_eq(await driver.read(addr), 0, f"{NAMES[addr]} reads zero")
    await driver.write(IN, MASK)
    assert_eq(await driver.read(IN), 0, "IN is read only")


@cocotb.test()
async def test_atomic_set_clear(dut) -> None:
    """Directed: set and clear touch only the bits written as one."""
    driver = await setup(dut)
    await driver.write(OUT, 0x0F & MASK)
    await driver.write(OUT_SET, 0x30 & MASK)
    assert_eq(await driver.read(OUT), 0x3F & MASK, "after OUT_SET")
    await driver.write(OUT_CLR, 0x05 & MASK)
    assert_eq(await driver.read(OUT), 0x3A & MASK, "after OUT_CLR")
    await driver.write(OUT_SET, 0)
    await driver.write(OUT_CLR, 0)
    assert_eq(await driver.read(OUT), 0x3A & MASK, "zero masks change nothing")


@cocotb.test()
async def test_direction_is_independent_of_value(dut) -> None:
    """Directed: pin_out carries OUT whatever DIR is; pin_oe carries DIR."""
    driver = await setup(dut)
    await driver.write(OUT, 0xC3 & MASK)   # preload before enabling
    await driver.write(DIR, 0xF0 & MASK)
    await driver.write(DIR, 0)
    await driver.write(DIR, MASK)
    assert_eq(await driver.read(OUT), 0xC3 & MASK, "OUT survives DIR changes")


@cocotb.test()
async def test_input_latency(dut) -> None:
    """Directed: IN follows the pads exactly SYNC_STAGES cycles later."""
    driver = await setup(dut)
    await driver.step(IN)
    value = 0xA5 & MASK
    await driver.step(pins=value)
    for cycle in range(SYNC_STAGES - 1):
        assert_eq(driver.model.read(IN), 0, f"IN not yet updated, cycle {cycle}")
        await driver.step()
    assert_eq(driver.model.read(IN), value, "IN after SYNC_STAGES cycles")


@cocotb.test()
async def test_edge_interrupts(dut) -> None:
    """Directed: rising and falling events latch only when enabled."""
    driver = await setup(dut)
    await driver.write(RISE_EN, 0x01)
    await driver.write(FALL_EN, 0x02 & MASK)
    await driver.step(STATUS)

    await driver.hold(SYNC_STAGES + 2, pins=0x03 & MASK)   # both rise
    assert_eq(driver.model.status, 0x01, "only the enabled rise latched")
    await driver.hold(SYNC_STAGES + 2, pins=0)             # both fall
    assert_eq(driver.model.status, 0x03 & MASK, "enabled fall latched too")

    await driver.write(STATUS, 0x01)
    assert_eq(driver.model.status, 0x02 & MASK, "W1C cleared one bit")
    await driver.write(STATUS, MASK)
    assert_eq(driver.model.status, 0, "W1C cleared the rest")


@cocotb.test()
async def test_high_pin_at_reset_release_is_not_an_edge(dut) -> None:
    """Directed: a pin already high when reset ends raises no interrupt.

    The event is the synchroniser filling with the pin's level. The design
    sees it as a rising edge, and it is one, but it is an edge of the
    synchroniser coming out of reset and not of the pin - which is why the
    interrupt enables come out of reset clear, and why enabling them after
    the pins have settled does not fire.
    """
    driver = await setup(dut, pins=MASK)
    await driver.hold(SYNC_STAGES + 2)
    await driver.write(RISE_EN, MASK)
    await driver.write(FALL_EN, MASK)
    await driver.hold(4)
    assert_eq(driver.model.status, 0, "no spurious event after settling")


# ---------------------------------------------------------------------------
# Randomised
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_random_activity(dut) -> None:
    """Randomised: writes to every register while the pins toggle."""
    rng = RandomStream("gpio_random")
    dut._log.info("random seed = %d", rng.seed)
    driver = await setup(dut)

    for _ in range(3000):
        addr = rng.between(0, 7)
        wr_en = int(rng.boolean(0.3))
        data = rng.corner_uint(WIDTH)
        pins = driver.pins
        if rng.boolean(0.25):
            pins ^= 1 << rng.between(0, WIDTH - 1)
        await driver.step(addr, wr_en, data, pins)


# ---------------------------------------------------------------------------
# Regression
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_event_beats_clear(dut) -> None:
    """Regression: an edge in the cycle its status bit is cleared is kept."""
    driver = await setup(dut)
    await driver.write(RISE_EN, 0x01)
    await driver.step(STATUS)
    await driver.step(pins=0x01)
    # The edge reaches the status register SYNC_STAGES edges after the pad
    # changed; issue the clear on exactly that edge.
    for _ in range(SYNC_STAGES - 1):
        await driver.step()
    await driver.write(STATUS, 0x01)
    assert_eq(driver.model.status, 0x01, "event survived the clear")
    await driver.write(STATUS, 0x01)
    assert_eq(driver.model.status, 0, "a later clear works")
