.. _ip-adder:

=====
adder
=====

Parameterised combinational adder with carry in and out, signed and unsigned
modes, and optional saturation.

Functional description
======================

The block computes ``a + b + carry_in`` and reports the carry out of the top
bit, whether the result was representable, and — when ``SATURATE`` is set — a
result clamped to the nearest representable value instead of a wrapped one.

It is deliberately combinational and has no clock. An adder is a leaf: where
it needs to be registered, the register belongs to the pipeline stage that
owns it, not to the adder. Building one in would mean carrying a clock and a
reset through every instantiation that does not want them, and would fix the
retiming boundary in the wrong place — the one decision that has to stay with
the caller, because only the caller knows where the stage boundary is.

The sum is produced one bit wider than the operands so that the carry out
falls out of the arithmetic rather than having to be reconstructed from the
operand sign bits. That is not a micro-optimisation: a reconstruction is one
more place for the signed and unsigned cases to diverge.

Signed and unsigned
-------------------

The distinction changes nothing about the sum itself. Two's complement
addition is bit-identical in both interpretations, which is exactly why a
single adder serves both. What it changes completely is what counts as an
overflow, and therefore what saturation does:

.. list-table::
   :header-rows: 1
   :widths: 16 42 42

   * - Mode
     - Overflow condition
     - Saturation limit
   * - unsigned
     - Carry out of the most significant bit.
     - All-ones.
   * - signed
     - The two operands share a sign that the result does not.
     - Most positive, or most negative, according to that shared sign.

Two numbers of opposite sign can never overflow a signed addition, which is
why the signed condition is an agreement between three sign bits rather than a
comparison against a limit. ``carry_out`` remains the true carry out of the top
bit in both modes; under ``SIGNED`` it carries no information about overflow,
and reading it as if it did is the defect this interface is shaped to prevent.

Saturation
----------

With ``SATURATE`` set, an overflowing result is clamped instead of wrapped.
That is what signal processing wants: a filter that wraps turns a loud sample
into a loud sample of the opposite sign, which is audible as a click, while
one that clamps merely distorts. Control logic usually wants the opposite — a
wrapping counter is correct — so the default is off.

The clamp is to exactly the limit, never to the limit minus the amount by
which the result overflowed. The sign of the operands selects which limit was
crossed, which is sound precisely because only same-sign pairs reach this path.

Block diagram
=============

.. code-block:: text

                  +--------------------------------------------+
     a   ========>|                                            |
      [W]         |   +------------------------------------+   |
     b   ========>|   |   {1'b0, a} + {1'b0, b} + carry_in |   |
      [W]         |   +------------------------------------+   |
                  |             [W+1] wide_sum                 |
     carry_in --->|              |            |                |
                  |              |            +--------------> |---> carry_out
                  |              |          bit [W]            |
                  |              v                             |
                  |   +---------------------+                  |
                  |   |  overflow decision  |----------------> |---> overflow
                  |   |  signed / unsigned  |                  |
                  |   +---------------------+                  |
                  |              |                             |
                  |              v                             |
                  |   +---------------------+                  |
                  |   | saturate or truncate|----------------> |===> sum
                  |   +---------------------+                  |      [W]
                  +--------------------------------------------+

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 18 14 10 16 42

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``WIDTH``
     - ``int unsigned``
     - 32
     - >= 2
     - Operand and result width. The lower bound is 2 because a one-bit
       signed operand has no magnitude bits.
   * - ``SIGNED``
     - ``int unsigned``
     - 0
     - 0 or 1
     - Two's complement interpretation. Selects the overflow rule and the
       saturation limits; the sum itself is unaffected.
   * - ``SATURATE``
     - ``int unsigned``
     - 0
     - 0 or 1
     - Clamp an overflowing result to the nearest representable value
       instead of wrapping.

Illegal parameter values are rejected at elaboration with ``$fatal``, so a
misconfiguration fails immediately rather than producing broken hardware.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 10 16 58

   * - Signal
     - Dir
     - Width
     - Description
   * - ``a``
     - in
     - ``WIDTH``
     - First operand.
   * - ``b``
     - in
     - ``WIDTH``
     - Second operand.
   * - ``carry_in``
     - in
     - 1
     - Carry into the least significant bit. Used as a plus one, and as the
       chaining input when several adders are cascaded.
   * - ``sum``
     - out
     - ``WIDTH``
     - Result. Saturated when ``SATURATE`` is set and the result overflowed,
       truncated otherwise.
   * - ``carry_out``
     - out
     - 1
     - Carry out of the most significant bit, in both interpretations.
   * - ``overflow``
     - out
     - 1
     - The result was not representable under the selected interpretation.

Usage examples
==============

Saturating bias in a signal path
--------------------------------

.. code-block:: systemverilog

   adder #(
     .WIDTH    (16),
     .SIGNED   (1),
     .SATURATE (1)
   ) u_bias (
     .a         (sample),
     .b         (offset),
     .carry_in  (1'b0),
     .sum       (biased_sample),
     .carry_out (),
     .overflow  (clipped)
   );

A wider adder from two narrower ones
------------------------------------

``carry_out`` of the low half drives ``carry_in`` of the high half. The
``overflow`` output of the low half is meaningless in this arrangement and the
one to use is the high half's.

.. code-block:: systemverilog

   adder #(.WIDTH (32), .SIGNED (0)) u_lo (
     .a (a[31:0]),  .b (b[31:0]),  .carry_in (1'b0),
     .sum (sum[31:0]), .carry_out (mid_carry), .overflow ()
   );

   adder #(.WIDTH (32), .SIGNED (1)) u_hi (
     .a (a[63:32]), .b (b[63:32]), .carry_in (mid_carry),
     .sum (sum[63:32]), .carry_out (), .overflow (overflow)
   );

Integration notes
-----------------

* The carry chain is the longest path in the block and its delay grows with
  ``WIDTH``. At large widths it is frequently the critical path of the stage
  that contains it. Register the result in the surrounding pipeline rather
  than asking for a registered adder.
* ``overflow``, not ``carry_out``, is the signal to branch on in signed mode.
* With ``SATURATE`` off, the block wraps. That is the correct behaviour for a
  counter and the wrong one for a signal path; the parameter exists so the
  choice is made explicitly at instantiation and is visible in the code.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_adder.py``
     - Identities and the carry in as a plus one, the unsigned wrap boundary,
       the four signed overflow corners, the saturation limits, corner-biased
       randomised operands, operands forced to share a sign so the overflow
       logic is actually exercised, an exhaustive sweep at narrow widths, a
       carry-chain regression, and a check that the result depends only on the
       present inputs.
   * - ``tb/tb_adder.sv``
     - Portable self-checking testbench: the directed corners, an exhaustive
       sweep at ``WIDTH=8`` and randomised vectors, against an independent
       reference model.
   * - ``formal/adder_formal.sv``
     - Exhaustive equivalence proof at ``WIDTH=16``: all four configurations
       against the header's overflow and saturation rules written as
       integer arithmetic on a wider sum.

The reference models in both suites are written from the specification in the
RTL header rather than from its body, so a mistake copied out of the design
would not be reproduced in the check.

.. code-block:: bash

   ctest --test-dir build -R 'adder'

Timing
======

The block is registered with ``NO_STA``. With no clock there is no setup or
hold check to make on it in isolation, and a standalone report of "no paths
found" is not evidence of anything. Its delay is covered by the timing
analysis of the sequential blocks that instantiate it, which include
``subtractor``, ``alu`` and ``mac``.
