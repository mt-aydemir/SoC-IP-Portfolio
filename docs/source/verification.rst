========================
Verification Methodology
========================

Every IP ships with two independent testbenches and a fixed set of test
classes. The requirement is not "there is a test" but "the block has been
shown to work at its boundaries, under randomised traffic, and against a
reference model".

Two testbenches per IP
======================

``cocotb/`` — the primary suite
   Python testbenches driven by cocotb against a Verilated model. Python gives
   direct access to a golden reference model written in a language where the
   reference is obviously correct: integer arithmetic for the arithmetic
   blocks, a list for a FIFO, ``hashlib`` for SHA-256. This is where the
   directed, randomised and regression tests live.

``tb/`` — the portable smoke test
   A self-checking SystemVerilog testbench with no Python dependency, compiled
   with ``verilator --binary``. It proves the block is usable on any plain
   SystemVerilog simulator and gives a fast signal during development. It ends
   by printing ``TEST PASSED``; the driver treats a missing banner as a
   failure, so a testbench that dies early cannot masquerade as a pass.

Required test classes
=====================

Directed tests
   Named, hand-written cases for the specification's corners: reset state,
   first transfer, last transfer, full, empty, overflow, underflow, maximum
   and minimum operands, protocol back-pressure.

Randomised tests
   Constrained-random traffic compared against the reference model, with
   corner-biased operand draws. Uniform random stimulus almost never hits zero,
   all-ones or the power-of-two boundaries where carry chains and saturation
   logic break, so ``RandomStream.corner_uint`` and ``corner_sint`` inject them
   explicitly.

Regression tests
   Long runs at several parameter configurations, plus a permanent test for
   every bug ever found. A fixed bug without a test that would have caught it
   is not a fixed bug.

Reproducibility
===============

Every randomised test seeds an explicit ``RandomStream`` and logs the seed. A
failing regression is replayed bit-for-bit:

.. code-block:: bash

   python scripts/run_cocotb.py \
       --top fifo_sync --name fifo_sync --module test_fifo_sync \
       --test-dir ip/memory/fifo_sync/cocotb \
       --build-dir build/replay --seed 1234567 \
       --sources ip/memory/fifo_sync/rtl/fifo_sync.sv

The shared library
==================

``verification/lib/socip`` exists so that fifty testbenches stay consistent.
Re-implementing clock generation or a scoreboard inside an individual test is a
review failure.

``socip.clocking``
   ``start_clock``, ``reset_active_low``, ``reset_active_high``, ``settle``,
   ``between_edges`` and the ``ClockDomain`` dataclass. Multi-clock IPs
   instantiate one ``ClockDomain`` per domain, which keeps the test body free
   of per-domain bookkeeping.

   Delays are always expressed in picoseconds. A delay such as ``period / 3``
   is frequently not representable at the simulator's time precision and makes
   a test fail for reasons that have nothing to do with the design.

``socip.scoreboard``
   A strict in-order ``Scoreboard``. An unexpected transaction, a mismatch, or
   any expected transaction still outstanding at ``check_done()`` is an error.

``socip.checks``
   ``assert_eq``, ``assert_within`` (for quantised DSP results), plus
   ``bits``, ``to_signed`` and ``sign_extend``. ``assert_eq`` reports both hex
   and decimal, because one of the two always makes the bug obvious.

   Any X or Z encountered while resolving a value is reported as a failure
   rather than silently coerced. An X on a checked output is a real defect.

``socip.stimulus``
   ``RandomStream`` with corner-biased draws and back-pressure gap generation,
   ``constrained_ints`` and ``weighted_choice``.

``socip.params``
   ``get_param(name, default)`` returns the elaboration parameter the model was
   built with. The runner exports every ``--param NAME=VALUE`` as
   ``SOCIP_PARAM_<NAME>``; reading parameters this way is portable across
   simulator back ends, unlike reading them through a simulator handle.

A testbench must never hard-code a width that the RTL parameterises:

.. code-block:: python

   from socip import get_param

   DATA_WIDTH = get_param("DATA_WIDTH", 8)
   DEPTH      = get_param("DEPTH", 16)

Writing a test module
=====================

.. code-block:: python

   """Cocotb regression for fifo_sync."""
   import cocotb
   from cocotb.triggers import RisingEdge

   from socip import ClockDomain, RandomStream, Scoreboard, assert_eq, get_param

   DATA_WIDTH = get_param("DATA_WIDTH", 8)
   DEPTH      = get_param("DEPTH", 16)


   async def setup(dut, period_ns: float = 10.0) -> ClockDomain:
       """Bring the DUT up in a known state and return its clock domain."""
       domain = ClockDomain(dut.clk, dut.rst_n, period_ns, "clk").start()
       dut.write_en.value = 0
       dut.read_en.value = 0
       await domain.reset()
       return domain


   @cocotb.test()
   async def test_reset_state(dut):
       """Directed: the FIFO reports empty and not full out of reset."""
       await setup(dut)
       assert_eq(dut.empty.value, 1, "empty after reset")
       assert_eq(dut.full.value, 0, "full after reset")


   @cocotb.test()
   async def test_random_traffic(dut):
       """Randomised: write/read traffic against an in-order scoreboard."""
       domain = await setup(dut)
       rng = RandomStream("fifo")
       dut._log.info("seed=%d", rng.seed)
       board = Scoreboard("fifo_sync")
       ...
       board.check_done()

Coverage of the flow, not of lines
==================================

The portfolio does not chase statement coverage. What is checked instead is
that each block passes all four flow stages under every parameter set that is
claimed to be supported:

* lint clean under ``-Wall``, with no in-source waivers and every tool-level
  exception declared in the IP's ``CMakeLists.txt`` (see
  :doc:`coding_style`);
* every functional test green under both testbenches;
* synthesis to a generic cell library without inferring latches or losing
  hierarchy checks;
* non-negative setup and hold slack at the documented clock period.

Waveforms
=========

Waveform generation is on by default and one VCD is written per test module:

.. code-block:: bash

   gtkwave build/waves/<ip>/<ip>.<module>.vcd

Turn it off for a fast regression:

.. code-block:: bash

   cmake -S . -B build -G Ninja -DSOC_IP_WAVES=OFF
