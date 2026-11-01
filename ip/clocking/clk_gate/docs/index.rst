.. _ip-clk_gate:

========
clk_gate
========

Glitch-free clock gate.

Functional description
======================

Clock gating is the cheapest dynamic power saving available: stopping a clock
stops every flip-flop it drives from toggling, and the clock tree itself is
often the largest single consumer of switching power in a design.

Doing it with a plain AND gate is wrong, and the reason is worth stating
precisely. The enable is produced by rising-edge logic, so it changes shortly
*after* a rising clock edge — in the middle of the clock's high phase. ANDing
it with the clock therefore chops the pulse that is currently in progress:

.. code-block:: text

   clk       __/‾‾‾\___/‾‾‾\___/‾‾‾\___
   enable    ______/‾‾‾‾‾‾‾‾‾\_________     changes mid-high-phase
   naive AND ______/‾\___/‾‾‾\_________     runt pulse, then a truncated one

A runt pulse is narrower than the minimum pulse width the flip-flops downstream
require. They may fail to capture, capture the wrong value, or go metastable —
and because the outcome depends on process, voltage and temperature, the
failure is silent and unreproducible.

The fix is to hold the enable in a level-sensitive latch that is transparent
only while the clock is **low**. Any change on the enable is then absorbed
during the low phase, and the value presented to the AND gate is already stable
by the time the clock rises:

.. code-block:: text

   clk       __/‾‾‾\___/‾‾‾\___/‾‾‾\___
   enable    ______/‾‾‾‾‾‾‾‾‾\_________
   latched   __________/‾‾‾‾‾‾‾‾‾\_____     updated only while clk is low
   gated_clk __________/‾‾‾\___________     whole pulses only

This is exactly the structure of an ASIC library's integrated clock gating
cell. Writing it as inferable RTL rather than instantiating a vendor primitive
is what keeps the block portable across FPGA vendors and ASIC flows.

The latch is the one place in the portfolio where a latch is correct.
Everywhere else an inferred latch is a defect, which is why the code uses
``always_latch``: it states the intent, so the tools can confirm that a latch
really is what was meant.

Block diagram
=============

.. code-block:: text

                    +--------------------------------------+
                    |                                      |
   enable --------->|--+                                   |
                    |  |   +-----------------+             |
   test_en -------->|--+-->| latch           |             |
                    |  OR  | transparent     |--- latched -+---+
                    |      | while clk == 0  |             |   |
                    |      +--------^--------+             |   |
                    |               |                      |  AND ---> gated_clk
   clk ------------>|---------------+----------------------+---+
                    |                                      |
                    +--------------------------------------+

Timing diagram
==============

The enable changes in the middle of the high phase, which is where a naive
implementation fails:

.. code-block:: text

               .    .    .    .    .    .    .    .
   clk      __/‾‾‾\____/‾‾‾\____/‾‾‾\____/‾‾‾\____/‾‾‾\__
               .    .    .    .    .    .    .    .
   enable   ______/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\__________
               .    .    .    .    .    .    .    .
                    ^ changes here, mid high phase
               .    .    .    .    .    .    .    .
   latched  ____________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\____
               .    .    .    .    .    .    .    .
                         ^ updated only while clk is low
               .    .    .    .    .    .    .    .
   gated_clk ____________/‾‾‾\____/‾‾‾\____/‾‾‾\_________
               .    .    .    .    .    .    .    .
                         every pulse is a whole pulse

The enable takes effect on the first rising edge after the low phase in which
it was presented, so there is up to one cycle of latency between requesting the
gate open and the first gated edge.

Parameter table
===============

The block has no parameters. It is a fixed structure whose correctness depends
on that structure, and there is nothing about it worth making configurable.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 8 8 68

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``
     - in
     - 1
     - Source clock.
   * - ``enable``
     - in
     - 1
     - Clock enable, produced by rising-edge logic in the ``clk`` domain.
   * - ``test_en``
     - in
     - 1
     - Test enable. Forces the gate open so scan chains keep clocking during
       test, independently of the functional enable. Tie low in normal
       operation; never drive it from functional logic.
   * - ``gated_clk``
     - out
     - 1
     - Gated clock. A generated clock: declare it in the SDC.

Usage examples
==============

Gating a subsystem
------------------

.. code-block:: systemverilog

   clk_gate u_gate_dsp (
     .clk       (clk_sys),
     .enable    (dsp_active),
     .test_en   (scan_mode),
     .gated_clk (clk_dsp)
   );

Building a fine-grained gate from a register bank's enable
----------------------------------------------------------

Gating a wide register bank whose write enable is already known is usually a
larger power win than gating a whole subsystem, because it applies every cycle
rather than only when the block is idle:

.. code-block:: systemverilog

   clk_gate u_gate_regfile (
     .clk       (clk_sys),
     .enable    (regfile_write_en),
     .test_en   (scan_mode),
     .gated_clk (clk_regfile)
   );

   always_ff @(posedge clk_regfile) begin
     regfile_q[write_addr] <= write_data;   // no enable term needed
   end

Integration notes
-----------------

* ``gated_clk`` is a **generated clock**. Declare it with
  ``create_generated_clock`` or the design behind it is untimed. This is the
  single most common integration mistake with a clock gate.
* Do not cascade clock gates without thought. Each adds a cycle of enable
  latency and another generated clock to constrain, and the insertion delay
  accumulates into clock skew against the ungated domain.
* The enable must come from a flip-flop in the ``clk`` domain. A combinational
  enable can glitch during the low phase, and the latch will faithfully capture
  the glitch.
* ``test_en`` must be driven by the scan controller, not by functional logic.
  Tying it to a functional signal defeats scan coverage of the gated domain.

Verification
============

The measurement is the point. A functional check that counts edges would pass
on a naive AND gate; only measuring the width of *every* pulse distinguishes a
correct clock gate from a broken one.

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_clk_gate.py``
     - No edges at all while disabled; exactly one gated edge per source edge
       while enabled; ``test_en`` forcing the gate open with the functional
       enable low; the enable changed a quarter of the way into the high phase,
       thirty times, which is where a naive AND gate produces a runt;
       randomised enable changes at ten different phase offsets; and a
       1000-cycle regression in which every pulse width is measured.
   * - ``tb/tb_clk_gate.sv``
     - Portable smoke test measuring every pulse with ``$realtime`` and
       checking that ``gated_clk`` never rises while the source clock is low.

.. code-block:: bash

   ctest --test-dir build -R 'clk_gate'
