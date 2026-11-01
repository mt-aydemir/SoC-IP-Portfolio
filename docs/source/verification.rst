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

Formal proofs
=============

Twelve blocks also carry a property wrapper, ``formal/<name>_formal.sv``,
proved by SymbiYosys in the flow's stage 2c. Simulation shows that a block
works on the traffic it was given; a proof shows it for every input
sequence from reset.

What a wrapper contains
-----------------------

* **Assumptions** that constrain the inputs to the interface protocol - an
  AXI source holds TVALID until TREADY, an APB requester follows a setup
  phase with an access phase - and the reset at time zero. Nothing else is
  assumed.
* **Assertions** of the block's guarantees, at the ports: results against a
  reference written from the header's definition, handshake rules, and
  ordering. Where a block only moves data, the source sends sequence
  numbers - the block never looks at the data, so nothing is lost - and
  every word must come out once, in order.
* **Probes** of internal state. k-induction needs properties that pin down
  the whole state, and a word held under a stall of any length is invisible
  at the ports. The free Yosys frontend has no hierarchical references, so
  a wrapper declares an undriven ``(* keep *)`` wire and names its source,

  .. code-block:: systemverilog

     // formal-connect: f_state = dut.state
     (* keep *) wire [7:0] f_state;

  and ``run_formal.py`` flattens the design and joins the two with
  ``connect -set``. The RTL carries no formal code at all.
* **Covers** of the behaviour the assertions are about - a full FIFO, a
  stalled beat, a SLVERR. An unreached cover fails the stage: it is how a
  set of assumptions that rules out the interesting behaviour, and so makes
  a proof vacuous, shows up.

The RTL is read with ``SYNTHESIS`` defined, so its simulation-only SVA,
which uses constructs the free frontend does not parse, stays out.

What is proved
--------------

.. list-table::
   :header-rows: 1
   :widths: 24 76

   * - Block
     - Proof
   * - ``adder``, ``subtractor``, ``comparator``, ``barrel_shifter``, ``alu``
     - Exhaustive equivalence at 16 bits (and 12 for the shifter) against
       integer-arithmetic references, every configuration at once.
   * - ``multiplier``
     - The exact product of the operands two cycles earlier, signed and
       unsigned, with the valid pipeline.
   * - ``fifo_sync``
     - Order, level, flags and hold at a non-power-of-two depth, with every
       stored word's position in the sequence stated.
   * - ``axi4_stream_slice``
     - All five modes: order with every sideband, capacity, hold and each
       mode's documented ready timing.
   * - ``apb_slave``
     - Both response modes: one register request per transfer, payload,
       response and wait-state timing.
   * - ``axi4_lite_slave``
     - Pairing of AW, W and AR with their requests, one response each,
       responses, hold and read/write alternation.
   * - ``mac_array``
     - Complete equivalence: every result is its vector's dot product, in
       order, with the credit flow control and the latency.
   * - ``lfsr_rng``
     - Equivalence with a bit-serial model of the recurrence, seeding and
       stalls included; the state never reaches zero.

A mutation campaign injected two or more bugs into each of these blocks;
every proof failed on every mutant.

Blocks without proofs are the CDC and clocking blocks, whose properties
need multi-clock formal modelling of metastability; the DSP and crypto
datapaths, where a proof at a useful width is beyond an SMT solver's
reach on multipliers and S-boxes and simulation against independent models
is the stronger evidence; and the peripherals, whose serial timing is
checked in simulation.

.. code-block:: bash

   ctest --test-dir build -L formal

Coverage of the flow, not of lines
==================================

The portfolio does not chase statement coverage. What is checked instead is
that each block passes every flow stage under every parameter set that is
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
