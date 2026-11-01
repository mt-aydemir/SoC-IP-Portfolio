"""Clock and reset helpers shared by every testbench in the portfolio."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

import cocotb
from cocotb.clock import Clock
from cocotb.handle import SimHandleBase
from cocotb.triggers import ClockCycles, RisingEdge, Timer


def start_clock(signal: SimHandleBase, period_ns: float = 10.0,
                start_high: bool = False) -> Clock:
    """Start a free-running clock on *signal* and return the Clock object."""
    clock = Clock(signal, period_ns, units="ns")
    cocotb.start_soon(clock.start(start_high=start_high))
    return clock


async def reset_active_low(signal: SimHandleBase, clk: SimHandleBase,
                           cycles: int = 5) -> None:
    """Assert an active-low reset for *cycles* clock cycles, then release it.

    The release is deliberately offset from the clock edge so that designs
    which sample reset synchronously never see a race in the simulator.
    """
    signal.value = 0
    await ClockCycles(clk, cycles)
    await Timer(1, units="ns")
    signal.value = 1
    await RisingEdge(clk)


async def reset_active_high(signal: SimHandleBase, clk: SimHandleBase,
                            cycles: int = 5) -> None:
    """Assert an active-high reset for *cycles* clock cycles, then release."""
    signal.value = 1
    await ClockCycles(clk, cycles)
    await Timer(1, units="ns")
    signal.value = 0
    await RisingEdge(clk)


async def settle(delay_ps: int = 1000) -> None:
    """Wait a short, precision-safe delay so signals settle before sampling.

    Always expressed in picoseconds: fractions of a nanosecond period such as
    ``period / 3`` are frequently not representable at the simulator's time
    precision and make the test fail for reasons unrelated to the design.
    """
    await Timer(int(delay_ps), units="ps")


async def between_edges(period_ns: float, fraction: float = 0.5) -> None:
    """Advance to a point *fraction* of the way through a clock period.

    Used to exercise asynchronous inputs (resets, external strobes) away from
    a clock edge. The delay is rounded to whole picoseconds so it is always
    representable.
    """
    await Timer(max(1, round(period_ns * fraction * 1000)), units="ps")


@dataclass
class ClockDomain:
    """A clock plus its active-low reset, driven as one unit.

    Multi-clock IPs (async FIFO, CDC blocks, DMA with separate bus clocks)
    instantiate one ClockDomain per domain, which keeps the test body free of
    per-domain bookkeeping.
    """

    clk: SimHandleBase
    rst_n: Optional[SimHandleBase] = None
    period_ns: float = 10.0
    name: str = "clk"
    _clock: Optional[Clock] = field(default=None, init=False, repr=False)

    def start(self, start_high: bool = False) -> "ClockDomain":
        self._clock = start_clock(self.clk, self.period_ns, start_high=start_high)
        return self

    async def reset(self, cycles: int = 5) -> None:
        if self.rst_n is None:
            raise ValueError(f"ClockDomain({self.name}) has no reset signal")
        await reset_active_low(self.rst_n, self.clk, cycles)

    async def cycles(self, n: int = 1) -> None:
        await ClockCycles(self.clk, n)

    async def edge(self) -> None:
        await RisingEdge(self.clk)

    @property
    def frequency_mhz(self) -> float:
        return 1000.0 / self.period_ns
