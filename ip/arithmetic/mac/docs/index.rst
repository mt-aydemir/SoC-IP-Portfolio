.. _ip-mac:

===
mac
===

Multiply-accumulate: ``acc <- acc + a*b``, with optional saturation and a
wider accumulator than the product.

Functional description
======================

On every cycle in which ``in_valid`` is asserted, the block multiplies ``a``
by ``b`` and adds the product to a running total, which appears on
``acc_out`` two cycles later with ``out_valid`` asserted for that cycle.
Asserting ``clear`` alongside a sample starts a new total from that sample's
product.

The multiply-accumulate is the inner loop of every filter, correlation and
matrix product. It exists here as a block rather than as two blocks wired
together by each caller because the two things callers get wrong — the
accumulator width and the clear timing — are precisely the things that are
settled once by having a block.

Structure
---------

The block instantiates ``multiplier`` and ``accumulator`` rather than
reimplementing either. What it adds is the clear alignment.

.. code-block:: text

                 +-------------------------------------------------------+
   a  ==========>|  +--------------+                                     |
   b  ==========>|  |  multiplier  |  product  +---------------+         |
   in_valid ---->|  |  LATENCY = 1 |==========>|               |         |
                 |  +--------------+           |  accumulator  |========>|==> acc_out
                 |         | product_valid     |               |         |      [ACC]
                 |         +------------------>| enable / load |-------->|--> overflow
                 |                             +---------------+         |
   clear ------->|  +--------------+                 ^                   |
                 |  | delay by     |  aligned_clear  |                   |
                 |  | MUL_LATENCY  |-----------------+                   |
                 |  +--------------+                                     |
                 |         (clear && in_valid)                           |
                 |                                                       |
                 |  +--------------+                                     |
                 |  | valid delay  |------------------------------------>|--> out_valid
                 |  +--------------+                                     |
                 +-------------------------------------------------------+
                            ^                    ^
                            |                    |
                           clk                 rst_n

Clear alignment
---------------

This is the part worth reading carefully, because it is the whole reason the
block is not two instantiations in the caller.

``clear`` is asserted **with the first sample of a new frame**, not a cycle
before it. The caller does not have to know the multiplier's latency; the
block delays the clear by exactly that latency so that it reaches the
accumulator in the same cycle as the product it is meant to precede.

Without the alignment:

* a clear arriving one cycle **early** zeroes the accumulator *after* the last
  product of the previous frame has already been added, so the previous frame's
  total is short by its last term;
* a clear arriving one cycle **late** zeroes it *after* the new frame's first
  product has been added, so the new frame's total is missing its first term.

Both failures produce totals that look almost right. In a filter they show up
as a small, data-dependent error at frame boundaries, which is the sort of
thing that is found weeks later in a system and in seconds by a cycle-accurate
testbench.

The clear is implemented as a ``load`` of the first product rather than as a
zero followed by an accumulate. "Clear, then accumulate this sample" therefore
costs no extra cycle and discards no sample: the accumulator is simply written
with the first product instead of being added to.

One consequence is worth stating: a ``clear`` asserted without ``in_valid``
does nothing. The clear is pipelined as ``clear && in_valid``, so it only
travels when there is a product for it to accompany. That is the only
definition under which the alignment can be maintained, and it means the
caller cannot clear the accumulator between frames without presenting a
sample — which is not a limitation in practice, because the first sample of
the next frame is exactly when a new total is wanted.

Accumulator width
-----------------

The product needs ``A_WIDTH + B_WIDTH`` bits. Accumulating *N* of them needs
another ``$clog2(N)`` on top. ``ACC_WIDTH`` is the caller's decision because
only the caller knows *N*; the block checks at elaboration that it is at least
wide enough for a single product, and reports ``overflow`` if the real total
exceeds it.

For a 16×16 filter with 128 taps that is 32 + 7 = 39 bits, so ``ACC_WIDTH`` of
40 is the honest choice and 32 is the common mistake.

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 18 14 10 22 36

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``A_WIDTH``
     - ``int unsigned``
     - 16
     - >= 1
     - First operand width.
   * - ``B_WIDTH``
     - ``int unsigned``
     - 16
     - >= 1
     - Second operand width.
   * - ``ACC_WIDTH``
     - ``int unsigned``
     - 40
     - >= ``A_WIDTH + B_WIDTH``
     - Accumulator width. The lower bound is the width of a single product;
       anything above it is headroom for the frame length.
   * - ``SIGNED``
     - ``int unsigned``
     - 1
     - 0 or 1
     - Interpret the operands as two's complement. Applies to the
       multiplication, the product extension and the accumulator's overflow
       rule alike.
   * - ``SATURATE``
     - ``int unsigned``
     - 0
     - 0 or 1
     - Clamp the accumulator at its limit instead of wrapping.

Illegal parameter combinations are rejected at elaboration with ``$fatal``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 10 20 54

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
       Clears the total and both pipelines.
   * - ``in_valid``
     - in
     - 1
     - The operands are valid this cycle. There is no back-pressure.
   * - ``clear``
     - in
     - 1
     - Start a new total with this sample. Only acted on when ``in_valid`` is
       also asserted.
   * - ``a``
     - in
     - ``A_WIDTH``
     - First operand.
   * - ``b``
     - in
     - ``B_WIDTH``
     - Second operand.
   * - ``out_valid``
     - out
     - 1
     - ``acc_out`` was updated on this edge. Asserted two cycles after the
       ``in_valid`` that caused the update.
   * - ``acc_out``
     - out
     - ``ACC_WIDTH``
     - The running total.
   * - ``overflow``
     - out
     - 1
     - The accumulation performed on this edge was not representable. Not
       latching: it describes this edge only.

Usage examples
==============

An FIR tap loop
---------------

``clear`` goes with the first tap of each output sample, so one accumulator
serves a stream of outputs with no gap between them.

.. code-block:: systemverilog

   mac #(
     .A_WIDTH   (16),
     .B_WIDTH   (16),
     .ACC_WIDTH (40),       // 32-bit products, up to 256 taps
     .SIGNED    (1),
     .SATURATE  (1)
   ) u_fir (
     .clk       (clk),
     .rst_n     (rst_n),
     .in_valid  (tap_valid),
     .clear     (first_tap),
     .a         (sample),
     .b         (coefficient),
     .out_valid (acc_valid),
     .acc_out   (filter_output),
     .overflow  (acc_clipped)
   );

   // The output sample is acc_out in the cycle after the last tap's
   // accumulation, which is two cycles after the last tap was presented.
   assign output_valid = acc_valid & last_tap_delayed;

A correlation
-------------

Identical structure; the second operand is the reference sequence rather than
a coefficient set, and the total is compared against a threshold rather than
emitted.

.. code-block:: systemverilog

   mac #(.A_WIDTH (12), .B_WIDTH (12), .ACC_WIDTH (32), .SIGNED (1)) u_corr (
     .clk (clk), .rst_n (rst_n),
     .in_valid (sample_valid),
     .clear    (window_start),
     .a (received), .b (reference),
     .out_valid (score_valid), .acc_out (score), .overflow ()
   );

Integration notes
-----------------

* Assert ``clear`` **with** the first sample, never before it. A caller that
  clears a cycle early gets a total short by the previous frame's last term.
* ``clear`` without ``in_valid`` does nothing. To abandon a frame without
  presenting a sample, reset the block or clear with the first sample of the
  next frame.
* There is no back-pressure. If the consumer can stall, buffer ``acc_out``
  downstream — do not gate ``clk``.
* Size ``ACC_WIDTH`` as ``A_WIDTH + B_WIDTH + $clog2(N)`` and connect
  ``overflow`` to something, even if only to an assertion. An unconnected
  overflow output is how a too-narrow accumulator stays invisible.
* ``out_valid`` marks the cycle in which ``acc_out`` has been updated. The
  total for a frame is therefore valid from the ``out_valid`` that follows its
  last sample, and stays valid until the next frame's first product arrives.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_mac.py``
     - A cycle-accurate model of the structure — one multiplier stage, a clear
       travelling with it, then the accumulate — compared after every edge.
       Covers the reset state; the two-cycle latency counted in edges; a
       hand-computed dot product; the clear alignment across a zero-gap frame
       boundary; back-to-back frames where every boundary lands while the
       previous frame still has a product in flight; gaps inside a frame;
       random frames of random length; ``in_valid`` and ``clear`` drawn
       independently every cycle; the accumulator limits; a mid-stream reset;
       and a 2000-cycle sustained run.
   * - ``tb/tb_mac.sv``
     - Portable self-checking testbench with the same structural reference
       model, the directed frames, the sign combinations, and 3000 randomised
       control vectors.

The model mirrors the *structure* rather than the equations, which is
deliberate: the arithmetic is already verified in ``multiplier`` and
``accumulator``, and what is new here is the timing relationship between them.
A model that only computed the dot product at the end of a frame would pass
with either misalignment.

.. code-block:: bash

   ctest --test-dir build -R 'mac'

Timing
======

The block is timed by OpenSTA on its synthesised netlist at the clock period
in its ``add_ip()`` registration. There are two paths worth knowing about: the
multiplier array, which retiming can improve by raising the multiplier's
``LATENCY``; and the accumulator's feedback path, which it cannot, because the
accumulator's register feeds the adder that produces its own next value.

At wide operand widths the accumulator is therefore the harder of the two, and
the fix is to restructure the accumulation rather than to add pipeline stages.
