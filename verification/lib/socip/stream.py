"""Ready/valid stream transactors.

Almost every block in the portfolio moves data over a ready/valid pair with
AXI4-Stream semantics, so the driver and monitor for that handshake live here
rather than being re-implemented in fifty testbenches.

Sampling discipline
-------------------

Getting the handshake right in a testbench is entirely a question of *when*
signals are sampled. A transfer occurs at a rising edge where ``valid`` and
``ready`` are both high, which means the deciding values are the ones settled
*before* that edge, not the ones visible after it. Reading a signal
immediately after ``await RisingEdge(clk)`` returns a value that is still
settling, and a testbench built that way reports failures that depend on
simulator scheduling rather than on the design.

Every class here therefore samples in the ``ReadOnly`` phase, which is the one
point in a cocotb time step where all combinational logic has converged and no
further writes are possible.
"""
from __future__ import annotations

from collections import deque
from typing import Callable, Deque, Iterable, Optional, Sequence

import cocotb
from cocotb.handle import SimHandleBase
from cocotb.triggers import Event, ReadOnly, RisingEdge

from socip.stimulus import RandomStream


async def sample(*signals: SimHandleBase) -> tuple[int, ...]:
    """Sample several handles at the same settled instant.

    All values come from a single ``ReadOnly`` phase, so they are guaranteed
    to describe one consistent picture of the interface. Sampling handles one
    at a time cannot promise that: each call advances to a different phase.

    .. important::
       This leaves the simulation in the ``ReadOnly`` phase, where writes are
       illegal. Await a clock edge before driving anything::

           valid, data = await sample(dut.m_valid, dut.m_data)
           await RisingEdge(dut.clk)     # back to a writable phase
           dut.m_ready.value = 1
    """
    await ReadOnly()
    return tuple(int(s.value) for s in signals)


async def sampled(signal: SimHandleBase) -> int:
    """Return one handle sampled in the settled ``ReadOnly`` phase.

    Use this instead of reading a handle directly after a clock edge whenever
    the value is produced by combinational logic or by a register that updates
    on that same edge: a direct read returns a value that is still settling.

    Carries the same restriction as :func:`sample` — the simulation is left in
    the ``ReadOnly`` phase, so await a clock edge before driving anything.
    """
    values = await sample(signal)
    return values[0]


class StreamSource:
    """Drives a ready/valid input stream, honouring back-pressure.

    Parameters
    ----------
    clk:
        Clock the interface is synchronous to.
    valid, ready:
        The handshake pair. ``valid`` is driven, ``ready`` is sampled.
    data:
        Optional payload handle. Omit for a handshake with no payload.
    name:
        Used in log messages.

    The driver obeys the protocol it is testing: once ``valid`` is asserted it
    stays asserted, with the payload held stable, until the sink accepts the
    word.
    """

    def __init__(self, clk: SimHandleBase, valid: SimHandleBase,
                 ready: SimHandleBase, data: Optional[SimHandleBase] = None,
                 name: str = "source") -> None:
        self.clk = clk
        self.valid = valid
        self.ready = ready
        self.data = data
        self.name = name
        self.sent = 0

    def idle(self) -> None:
        """Drive the interface to its inactive state. Call before reset."""
        self.valid.value = 0
        if self.data is not None:
            self.data.value = 0

    async def send(self, value: Optional[int] = None) -> None:
        """Transfer one word, blocking until the sink accepts it."""
        if self.data is not None and value is not None:
            self.data.value = value
        self.valid.value = 1

        # Wait for a cycle in which ready is high at the sampling point; the
        # transfer then completes at the edge that follows.
        while True:
            await ReadOnly()
            if int(self.ready.value) == 1:
                break
            await RisingEdge(self.clk)

        await RisingEdge(self.clk)
        self.valid.value = 0
        self.sent += 1

    async def send_many(self, values: Iterable[int],
                        gap: Optional[Callable[[], int]] = None) -> None:
        """Transfer a sequence of words, optionally with idle gaps between.

        *gap* is called once per word and returns the number of idle cycles to
        insert before the next transfer; pass ``rng.delay`` for randomised
        back-pressure from the source side.
        """
        for value in values:
            await self.send(value)
            if gap is not None:
                for _ in range(gap()):
                    await RisingEdge(self.clk)


class StreamSink:
    """Observes a ready/valid output stream and optionally applies back-pressure.

    Started with :meth:`start`, the sink runs as a background coroutine that
    records every accepted word. Words are available through :meth:`recv`, the
    :attr:`received` list, or an optional per-word callback.

    Parameters
    ----------
    ready_probability:
        Probability that ``ready`` is asserted in any given cycle. 1.0 drives a
        sink that never stalls; a lower value exercises the stall path. When
        below 1.0 an :class:`~socip.stimulus.RandomStream` must be supplied so
        the back-pressure pattern is reproducible from the logged seed.
    """

    def __init__(self, clk: SimHandleBase, valid: SimHandleBase,
                 ready: SimHandleBase, data: Optional[SimHandleBase] = None,
                 rst_n: Optional[SimHandleBase] = None,
                 name: str = "sink",
                 ready_probability: float = 1.0,
                 rng: Optional[RandomStream] = None,
                 callback: Optional[Callable[[int], None]] = None) -> None:
        if ready_probability < 1.0 and rng is None:
            raise ValueError(
                f"StreamSink({name}): randomised back-pressure needs an "
                "explicit RandomStream so the run is reproducible")

        self.clk = clk
        self.valid = valid
        self.ready = ready
        self.data = data
        self.rst_n = rst_n
        self.name = name
        self.ready_probability = ready_probability
        self.rng = rng
        self.callback = callback

        self.received: list[int] = []
        self._queue: Deque[int] = deque()
        self._arrival = Event()
        self._task = None

    def start(self) -> "StreamSink":
        """Begin driving ready and recording accepted words."""
        self.ready.value = int(self.ready_probability >= 1.0)
        self._task = cocotb.start_soon(self._run())
        return self

    def stop(self) -> None:
        if self._task is not None:
            self._task.kill()
            self._task = None

    @property
    def count(self) -> int:
        return len(self.received)

    async def recv(self) -> int:
        """Return the next accepted word, waiting for it if necessary."""
        while not self._queue:
            self._arrival.clear()
            await self._arrival.wait()
        return self._queue.popleft()

    async def _run(self) -> None:
        while True:
            await RisingEdge(self.clk)

            # Back-pressure is decided for the cycle that is starting, before
            # the sampling point, so the value is stable when it is read.
            if self.ready_probability < 1.0:
                self.ready.value = int(self.rng.boolean(self.ready_probability))

            await ReadOnly()

            if self.rst_n is not None and int(self.rst_n.value) == 0:
                continue
            if int(self.valid.value) != 1 or int(self.ready.value) != 1:
                continue

            word = int(self.data.value) if self.data is not None else 0
            self.received.append(word)
            self._queue.append(word)
            self._arrival.set()
            if self.callback is not None:
                self.callback(word)


async def expect_stream(sink: StreamSink, expected: Sequence[int],
                        timeout_cycles: int = 10_000) -> None:
    """Wait until *sink* has accepted ``len(expected)`` words, then compare.

    Raises ``AssertionError`` on the first mismatch, or if the words do not
    arrive within *timeout_cycles*, which turns a hung design into a readable
    failure rather than a simulation that runs until the global timeout.
    """
    for _ in range(timeout_cycles):
        if sink.count >= len(expected):
            break
        await RisingEdge(sink.clk)
    else:
        raise AssertionError(
            f"{sink.name}: expected {len(expected)} word(s), only "
            f"{sink.count} arrived within {timeout_cycles} cycles")

    for index, (want, got) in enumerate(zip(expected, sink.received)):
        if want != got:
            raise AssertionError(
                f"{sink.name}: word {index} mismatch: "
                f"expected 0x{want:X}, got 0x{got:X}")
