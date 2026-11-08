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

UVM testbenches
===============

The two register bridges, ``apb_slave`` and ``axi4_lite_slave``, also have a
UVM 1800.2-2020 environment in ``uvm/``, run in the flow's stage 2d on
Verilator, which supports UVM 2020-3.2 from release 5.052. Each is a
conventional environment written in SystemVerilog:

* a **bus agent** - sequencer, driver and monitor - acting as the APB4
  requester or the AXI4-Lite manager, driven by constrained-random sequence
  items (address windows, strobes, protection, gaps; for AXI4-Lite the
  relative timing of AW and W and the response back-pressure, with a write
  and a read in flight together);
* a **reactive register-side component** standing in for the register
  block: random ``reg_ready`` wait states, read data from its own memory and
  an error for addresses at or above ``0x800``;
* a **scoreboard** that pairs every bus transaction with exactly one
  register request, checks the payload and the response, and predicts every
  read from an independent reference memory - for AXI4-Lite in the order the
  register block saw the requests, which is what decides what a read
  returns;
* a **covergroup** over kinds, errors, wait states, strobes and, for
  AXI4-Lite, the AW/W order, back-pressure and read/write overlap.

A test passes only when the scoreboard checked every transaction, the
random test reached full coverage, and no ``UVM_ERROR`` or ``UVM_FATAL`` was
reported; ``scripts/run_uvm.py`` reads the report counts, because a
``UVM_FATAL`` ends a Verilator simulation with status zero.

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Test
     - Contents
   * - ``apb_random_test``
     - 600 constrained-random transfers against a register block that
       stalls 40% of the time, in both response modes.
   * - ``apb_back_to_back_test``
     - 200 transfers with no gaps and no wait states, and the exact cycle
       count: two per transfer on the direct path, three registered.
   * - ``axil_random_test``
     - 600 mixed transactions with random channel timing, back-pressure and
       wait states.
   * - ``axil_saturation_test``
     - 400 transactions with no gaps, no back-pressure and no wait states.

A mutation campaign confirmed the environments bite: a request issued twice,
read data returned on a write, a lost error response, a write accepted while
its response was still owed and write data leaking onto a read request each
fail them.

Two simulator limits shape the code. There are no clocking blocks - drivers
assign one time unit after the rising edge and monitors sample on the
falling edge - because data through a virtual interface's clocking block
does not yet propagate reliably (verilator/verilator#7688). And coverage is
read for the whole covergroup only, since ``get_coverage()`` of a single
coverpoint is not yet supported. Constrained randomisation calls an SMT
solver at run time; the flow passes the Z3 it finds for the formal stage.

.. code-block:: bash

   ctest --test-dir build -L uvm

Formal proofs
=============

Twenty blocks also carry a property wrapper, ``formal/<name>_formal.sv``,
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

Clock-domain crossings and clocks
---------------------------------

Blocks with several clocks, or with logic on both edges, register
``FORMAL_MULTICLOCK``. Their clocks are then ordinary free inputs, and each
solver step may change any input, so every ratio and phase between clocks
is explored, edges on the same step included. A flop clocked between two
steps samples the earlier one, and captures nothing on the step its reset
is released.

That is also how metastability is covered. An input changing near a clock
edge resolves, in silicon, to its old or its new value; with free clocks
the solver places every input change on both sides of every edge, so both
outcomes are explored. What is not modelled is metastability lasting past
the next flop - the assumption every synchroniser is built on. Skew across
a multi-bit bus is handled the way the designs handle it: the proofs
assert that a bus is stable whenever the other domain samples it.

Each reset is assumed low at the start and released once, at any time and
in either order across domains - one reset per domain, as the headers
specify.

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
   * - ``cdc_sync_2ff``, ``cdc_reset_sync``
     - Exact latency after an input settles; asynchronous reset assertion
       and release on exactly the STAGES-th clean edge.
   * - ``cdc_pulse_sync``
     - One destination pulse per accepted source pulse, one cycle long,
       one event in flight, busy while in flight, under any clock ratio.
   * - ``cdc_handshake``
     - Every word delivered once, in order and intact, the payload stable
       while the other domain may sample it, under any clock ratio.
   * - ``clk_gate``
     - No glitch: the gated clock changes only with the clock, and the
       enable is taken from the last low phase.
   * - ``clk_mux``
     - The branch enables are exclusive and change only while their clock
       is low; every output pulse is a whole high phase of one clock.
   * - ``clk_divider``
     - No glitch, a 50% duty cycle in half-periods at an odd and an even
       divisor, enable behaviour and the ``clk_en`` period.
   * - ``reset_controller``
     - Exact release time of every stage after the asynchronous reset and
       after a software reset; asynchronous assertion.

A mutation campaign injected two or more bugs into each of these blocks -
among them a clock gate without its latch, a mux enable moved to the wrong
clock edge and a reset synchroniser with synchronous assertion; every
proof failed on every mutant.

Blocks without proofs are the DSP and crypto datapaths, where a proof at a
useful width is beyond an SMT solver's reach on multipliers and S-boxes and
simulation against independent models is the stronger evidence; the
memories and peripherals other than ``fifo_sync``, covered in simulation;
and the ML accelerators other than ``mac_array``.

.. code-block:: bash

   ctest --test-dir build -L formal

Code coverage
=============

Code coverage is measured, not gated. The instrumented builds are slower, so
the stage is off by default:

.. code-block:: bash

   cmake -S . -B build-cov -G Ninja -DSOC_IP_ENABLE_COVERAGE=ON -DSOC_IP_WAVES=OFF
   ctest --test-dir build-cov -L coverage -j8
   cmake --build build-cov --target coverage-summary

``coverage.<category>.<name>`` merges the block's cocotb and SystemVerilog
testbench runs and counts the line, branch and toggle points of its own RTL.
``reports/coverage/<name>.txt`` lists every point never hit. A point counts as
covered when any instance of it was hit, in any parameter set. UVM runs are not
included.

Two kinds of line point are left out, because a miss on them says nothing about
the tests: assertion declarations and failure actions, which only a failing
assertion would reach, and lookup tables, whose functions sit between
``verilator coverage_off`` and ``coverage_on`` pragmas.

The points still missed are, by kind:

* ``default`` arms of case statements over fully decoded state, which no legal
  state reaches;
* the ``else`` of the push-and-pop case in the two-entry output stages of
  ``fifo_sync``, ``fifo_async`` and ``bram_ctrl``: it needs the stage full while
  a word arrives, which their formal invariants rule out;
* elaboration-time parameter checks, which run before simulation starts;
* three error corners of ``cnn_accel``'s command parser: a malformed header
  that ends its frame, a short data frame, and the status reply held back by
  the output stream;
* toggles of configuration inputs and counters whose high bits only a slower
  bit rate than any test uses would set, in ``uart`` above bit 11 and in
  ``i2c_master``.

A testbench that needs a data file names it relative to ``SOC_IP_TB_DIR``,
which ``run_svtb.py`` defines as the testbench's directory; the RAMs' preload
files are read that way.

What else the flow checks
=========================

Beyond code coverage, each block has to pass every flow stage under every
parameter set that is claimed to be supported:

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
