.. _ip-cdc_reset_sync:

==============
cdc_reset_sync
==============

Reset synchroniser with asynchronous assertion and synchronous release.

Functional description
======================

A raw power-on or system reset has no timing relationship to any clock in the
design. That asynchrony is useful in one direction and dangerous in the other.

**Assertion should be asynchronous.** The design must reach a known state even
if no clock is running — during power-up, during a clock reconfiguration, or
when a PLL has lost lock. A synchronous reset cannot do this: with no clock
edge, nothing is sampled and nothing resets.

**Release must be synchronous.** Every flip-flop has a *recovery* time (how
long before a clock edge the reset must be released) and a *removal* time (how
long after). A release edge that lands inside that window can drive the
flip-flop metastable exactly as a data-path violation would. Worse, because the
release edge reaches different flip-flops at slightly different times, some can
leave reset one cycle later than others. A state machine whose bits leave reset
on different cycles does not start in its reset state; it starts somewhere
arbitrary.

This block provides both behaviours. The asynchronous input clears the whole
chain directly, so assertion is immediate and needs no clock. On release, a
constant ``1`` is shifted through the chain, so the output rises ``STAGES``
clock edges later, synchronously to the local clock. The first flip-flop may go
metastable on the release edge; each further stage gives it another full clock
period to resolve.

**One instance is required per clock domain.** Feeding one domain's
synchronised reset into another domain does not work: relative to the second
domain the release edge is asynchronous again, and the problem is simply moved.

Block diagram
=============

.. code-block:: text

                    +-----+     +-----+           +-----+
        1'b1  ----->| D Q |---->| D Q |-- ... --->| D Q |----> rst_n_out
                    |     |     |     |           |     |
                    | FF0 |     | FF1 |           |FFn-1|
                    +--^--+     +--^--+           +--^--+
                       |o          |o                |o        o = async clear
    clk ---------------+-----------+-------- ... ----+
                       |           |                 |
    arst_n_in ---------+-----------+-------- ... ----+
                    (asynchronous clear on every stage)

    Assertion  : arst_n_in falls  -> every stage clears immediately
    Release    : arst_n_in rises  -> a 1 walks the chain, STAGES edges

Timing diagram
==============

``STAGES = 3``:

.. code-block:: text

               .    .    .    .    .    .    .    .    .
   clk      __/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__
               .    .    .    .    .    .    .    .    .
   arst_n_in ___________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\____/‾‾‾‾‾‾
               .    .    .    .    .    .    .    .    .
   stage 0  _______________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\____/‾‾‾‾‾‾
               .    .    .    .    .    .    .    .    .
   stage 1  ____________________/‾‾‾‾‾‾‾‾‾‾‾‾‾\_________/‾
               .    .    .    .    .    .    .    .    .
   rst_n_out ________________________/‾‾‾‾‾‾‾‾\____________
               .    .    .    .    .    .    .    .    .
                    |<-- 3 edges -->|         |
                     synchronous release       immediate,
                                               asynchronous
                                               assertion

Note the asymmetry, which is the whole point of the block: the falling edge of
``rst_n_out`` follows ``arst_n_in`` with no clock involved, while the rising
edge waits for three clock edges.

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 16 20 12 14 38

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``STAGES``
     - ``int unsigned``
     - 2
     - >= 2
     - Length of the synchroniser chain, and therefore the release latency in
       clock cycles. Two is the minimum; three is used at high clock rates or
       where the reliability target is high.

``STAGES < 2`` is rejected at elaboration with ``$fatal``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 8 10 14 52

   * - Signal
     - Dir
     - Width
     - Domain
     - Description
   * - ``clk``
     - in
     - 1
     - dest
     - Clock of the domain this reset serves.
   * - ``arst_n_in``
     - in
     - 1
     - **async**
     - Raw asynchronous reset, active low. Typically the board power-on reset
       or a system reset with no relationship to ``clk``.
   * - ``rst_n_out``
     - out
     - 1
     - dest
     - Synchronised reset, active low. Distribute this to every block in the
       domain.

Usage examples
==============

One instance per domain
-----------------------

.. code-block:: systemverilog

   // Core domain
   cdc_reset_sync #(.STAGES(3)) u_rst_sync_core (
     .clk       (clk_core),
     .arst_n_in (por_n),
     .rst_n_out (rst_n_core)
   );

   // Peripheral domain: a second instance, not a copy of rst_n_core
   cdc_reset_sync #(.STAGES(2)) u_rst_sync_periph (
     .clk       (clk_periph),
     .arst_n_in (por_n),
     .rst_n_out (rst_n_periph)
   );

Combining reset sources
-----------------------

Combine the sources *before* the synchroniser, never after. Combinational logic
on the synchronised output would reintroduce glitches into a signal the rest of
the design trusts:

.. code-block:: systemverilog

   assign reset_sources_n = por_n & ~soft_reset & ~watchdog_timeout;

   cdc_reset_sync #(.STAGES(3)) u_rst_sync (
     .clk       (clk_core),
     .arst_n_in (reset_sources_n),
     .rst_n_out (rst_n_core)
   );

Integration notes
-----------------

* Do not gate or otherwise qualify ``rst_n_out``. It is a reset tree root.
* If the clock can stop while ``arst_n_in`` is released, the output stays in
  whatever state the chain last reached — assertion still works, but release
  needs ``STAGES`` edges to complete. Bring the clock up before releasing the
  reset.
* Apply ``scripts/cdc_reset_sync.sdc``. Without it, an optimiser may merge or
  remove the intermediate stages, whose only purpose is to spend time.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_cdc_reset_sync.py``
     - Output held asserted while the input is low; release latency of exactly
       ``STAGES`` edges; assertion applied a third of the way through a clock
       period, proving it does not wait for an edge; a reset glitch 5 % of a
       clock period wide, which a synchronous reset would miss entirely;
       randomised assertion phases; and back-to-back assert/release cycles that
       prove the chain flushes completely every time.
   * - ``tb/tb_cdc_reset_sync.sv``
     - Portable self-checking smoke test covering the same behaviour.
   * - ``formal/cdc_reset_sync_formal.sv``
     - Proof with free-running clocks: assertion at once, release
       exactly on the STAGES-th rising edge that finds the input high, at
       two and three stages.

.. code-block:: bash

   ctest --test-dir build -R 'cdc_reset_sync'
