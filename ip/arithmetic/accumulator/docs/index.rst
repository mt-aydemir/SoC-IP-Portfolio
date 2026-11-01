.. _ip-accumulator:

===========
accumulator
===========

Parameterised accumulator with load, clear, enable and optional saturation.

Functional description
======================

The block maintains a running total. On each rising clock edge it either
zeroes the total, replaces it with ``load_data``, adds ``data_in`` to it, or
holds it unchanged, according to the control inputs applied before that edge.

The accumulator is **wider than its input**, which is the whole point of
having one as an IP rather than writing ``sum <= sum + x`` inline. Adding *N*
values of ``DATA_WIDTH`` bits needs ``DATA_WIDTH + $clog2(N)`` bits to hold
every possible result, and getting that width wrong is the most common defect
in accumulate loops: the sum is correct for the test vectors and wraps on real
data, months later, on a long input.

Growth
------

``ACC_WIDTH`` is the caller's decision, because only the caller knows how many
values will be accumulated between clears. The block does not guess. What it
does do is report overflow, so a wrong choice is visible rather than silent.

For a 16-bit addend accumulated over 1024 samples, the honest width is
16 + 10 = 26 bits, and 16 is the common mistake.

Addend extension
----------------

The addend is extended to the accumulator width before being added: sign
extension in the signed configuration, zero extension otherwise. Getting this
wrong is silent in a way that is worth stating explicitly, because an unsigned
extension of a negative value adds a huge positive number instead of a small
negative one — so the accumulator looks perfectly correct until the inputs
first go negative.

Saturation
----------

With ``SATURATE`` set, the accumulator clamps at the limit instead of
wrapping. Signal processing wants this: an accumulator that wraps turns a
large positive sum into a large negative one, which in a filter is an audible
click, while one that clamps merely distorts. A statistics counter wants the
opposite, so the default is off.

The limits follow the interpretation — most positive and most negative for
signed, all-ones for unsigned — and the clamp is to exactly the limit, never
to the limit minus the amount by which the sum passed it.

Saturation is sticky in effect but **not in state**. Once clamped the total
stays at the limit only while inputs keep pushing it there, and an input of
the opposite sign moves it back. That is deliberate: a latching saturation
indication belongs to the consumer, and ``overflow`` exists for exactly that
purpose. For the same reason ``overflow`` describes the addition performed on
the current edge, so an idle cycle clears it even though the total has not
changed.

Control priority
----------------

``clear`` beats ``load`` beats ``enable``. Clear is the recovery path and must
always work, which is why nothing can mask it. Asserting several controls in
the same cycle is legal — the priority rule is what makes the outcome well
defined — and the verification walks the whole matrix of combinations rather
than only the ones a well-behaved caller would produce.

Block diagram
=============

.. code-block:: text

                 +--------------------------------------------------+
   data_in =====>| sign/zero extend to ACC_WIDTH --> addend          |
     [D]         |                                     |            |
                 |                                     v            |
                 |   acc_out -------------------->  (+) [ACC+1]     |
                 |      |                              |            |
                 |      |                   +----------+---------+  |
                 |      |                   | carry / sign rule  |  |
                 |      |                   +----------+---------+  |
                 |      |                              |            |
                 |      |                              v            |
                 |      |                   +---------------------+ |
                 |      +------------------>| saturate or truncate| |
                 |                          +---------------------+ |
                 |                                     |            |
   load_data ===>|-----------------------------+       |            |
     [ACC]       |                             v       v            |
   clear ------->|  priority select: clear > load > enable > hold    |
   load -------->|                             |                     |
   enable ------>|                             v                     |
                 |                    +-----------------+            |
                 |                    | acc_out register|===========>|==> acc_out
                 |                    +-----------------+            |     [ACC]
                 |                    | overflow register|---------->|--> overflow
                 |                    +-----------------+            |
                 +--------------------------------------------------+
                            ^                    ^
                            |                    |
                           clk                 rst_n

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 18 14 10 20 38

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 16
     - >= 1
     - Width of the value added each cycle.
   * - ``ACC_WIDTH``
     - ``int unsigned``
     - 32
     - >= ``DATA_WIDTH``, >= 2
     - Width of the accumulator. The lower bound exists because a total
       narrower than its own addend cannot represent even the first value.
   * - ``SIGNED``
     - ``int unsigned``
     - 1
     - 0 or 1
     - Interpret the addend and the total as two's complement. Selects both
       the addend extension and the overflow rule.
   * - ``SATURATE``
     - ``int unsigned``
     - 0
     - 0 or 1
     - Clamp at the limit instead of wrapping.

Illegal parameter combinations are rejected at elaboration with ``$fatal``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 10 16 58

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``
     - in
     - 1
     - Rising-edge clock.
   * - ``rst_n``
     - in
     - 1
     - Active-low reset. Asserted asynchronously, released synchronously.
       Zeroes both the total and the flag.
   * - ``clear``
     - in
     - 1
     - Zero the total. Highest priority; nothing can mask it.
   * - ``load``
     - in
     - 1
     - Replace the total with ``load_data``. Beaten by ``clear``.
   * - ``enable``
     - in
     - 1
     - Add ``data_in`` to the total. Beaten by ``clear`` and ``load``.
   * - ``data_in``
     - in
     - ``DATA_WIDTH``
     - The addend, extended to ``ACC_WIDTH`` according to ``SIGNED``.
   * - ``load_data``
     - in
     - ``ACC_WIDTH``
     - The new total when ``load`` is asserted.
   * - ``acc_out``
     - out
     - ``ACC_WIDTH``
     - The running total, registered.
   * - ``overflow``
     - out
     - 1
     - The addition performed on this edge was not representable. Cleared by
       ``clear``, by ``load``, and by any cycle in which no addition happened.

Usage examples
==============

A frame-based total
-------------------

``clear`` asserted with the first sample of a frame starts the total afresh
without costing a cycle, because clear and the first accumulate are separate
controls on the same edge — the clear wins, and the first sample is then added
on the following edge.

.. code-block:: systemverilog

   accumulator #(
     .DATA_WIDTH (16),
     .ACC_WIDTH  (40),
     .SIGNED     (1),
     .SATURATE   (1)
   ) u_acc (
     .clk       (clk),
     .rst_n     (rst_n),
     .clear     (frame_start),
     .load      (1'b0),
     .enable    (sample_valid),
     .data_in   (sample),
     .load_data ('0),
     .acc_out   (frame_total),
     .overflow  (total_clipped)
   );

Resuming a saved total
----------------------

``load`` is what makes the block usable for an accumulation that is
interleaved across several contexts: the total for each context is held
outside the block and reloaded when that context is scheduled again.

.. code-block:: systemverilog

   // Restore the running total for the channel about to be processed.
   accumulator #(.DATA_WIDTH (16), .ACC_WIDTH (32)) u_acc (
     .clk (clk), .rst_n (rst_n),
     .clear     (1'b0),
     .load      (channel_switch),
     .enable    (sample_valid),
     .data_in   (sample),
     .load_data (saved_total[channel]),
     .acc_out   (total),
     .overflow  (clipped)
   );

Integration notes
-----------------

* Size ``ACC_WIDTH`` as ``DATA_WIDTH + $clog2(N)`` for the largest *N* between
  clears, and connect ``overflow`` to something even if only to an assertion.
  An unconnected overflow output is how a too-narrow accumulator stays
  invisible.
* ``overflow`` is not latching. If the consumer needs "did this frame clip at
  any point", it must hold the flag itself.
* The adder is ``ACC_WIDTH`` bits wide and its carry chain is the block's
  critical path, so a wide accumulator running fast may need its addition
  pipelined outside this block.
* ``data_in`` is extended according to ``SIGNED``, so the parameter must match
  the interpretation of the data. A signed data stream into an unsigned
  accumulator produces a plausible-looking total that is wrong only for
  negative samples.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_accumulator.py``
     - A cycle-accurate Python replica of the specification, stepped once per
       clock edge with the controls applied before that edge and compared
       after it. Covers the reset state, accumulation, hold, load, clear, the
       whole control-priority matrix, both saturation limits, randomised
       control every cycle, totals loaded within one addend of a limit and
       then driven across it, a long accumulation past the point a too-narrow
       total would wrap, the non-sticky saturation property, and a mid-stream
       reset.
   * - ``tb/tb_accumulator.sv``
     - Portable self-checking testbench whose reference total is a 64-bit
       integer, so the model decides the answer in arithmetic that cannot
       itself overflow, with 4000 randomised control vectors.

The cycle-accurate comparison is the point. An accumulator's characteristic
defects are not arithmetic but temporal — a flag that describes the previous
addition, a clear that lands one edge late, a total that updates on a cycle
where ``enable`` was low — and a model that is only checked at the end of a
run cannot see any of them.

.. code-block:: bash

   ctest --test-dir build -R 'accumulator'

Timing
======

The block is timed by OpenSTA on its synthesised netlist at the clock period
in its ``add_ip()`` registration. The critical path is the full-width carry
chain plus the saturation and priority multiplexing, all of which is in the
register's data path, so the reported slack scales with ``ACC_WIDTH`` and is
the number to watch when widening the total.
