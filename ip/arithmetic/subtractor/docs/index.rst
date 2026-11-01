.. _ip-subtractor:

==========
subtractor
==========

Parameterised combinational subtractor with borrow in and out, signed and
unsigned modes, and optional saturation.

Functional description
======================

The block computes ``a - b - borrow_in`` and reports whether the result went
below zero, whether it was representable under the selected interpretation,
and — when ``SATURATE`` is set — a result clamped to the correct limit instead
of a wrapped one.

It does not contain a carry chain of its own. Two's complement subtraction is
addition of the inverted subtrahend with the carry in set:

.. code-block:: text

   a - b - borrow_in  ==  a + ~b + ~borrow_in

The identity holds because ``~b == -b - 1``, so ``a + ~b + 1 == a - b``. Adding
``~borrow_in`` rather than a constant one folds the incoming borrow in for
free. Reusing ``adder`` this way means the portfolio contains exactly one
implementation of two's complement addition with overflow detection, which is
one place for that logic to be wrong rather than two.

What the adder does not supply
------------------------------

Three things do not come for free from the instantiated adder.

``borrow_out``
   The adder produces a carry out, and for a subtraction the borrow is its
   complement: no carry out of the top bit means the result went below zero.

unsigned saturation
   The adder clamps an unsigned overflow to all-ones, which is the right limit
   for an addition and the wrong one for a subtraction. An unsigned
   subtraction that goes below zero must clamp to **zero**, so saturation is
   applied in this block and the adder is instantiated with it disabled.

unsigned ``overflow``
   The adder reports its unsigned overflow as the carry out — and a carry out
   of ``a + ~b + ~borrow_in`` means the subtraction did *not* go below zero.
   Forwarding it would invert the flag, so the unsigned overflow is taken from
   ``borrow_out`` instead. This was a real defect in the first implementation;
   see the changelog.

Signed overflow, by contrast, needs no special handling. The adder computes it
as "both operands share a sign the result does not", and since ``~b`` has the
opposite sign bit to ``b``, that expression evaluated on ``(a, ~b)`` is exactly
the signed subtraction overflow condition. A subtraction can only overflow
when its operands differ in sign, which is the mirror image of the addition
rule.

Block diagram
=============

.. code-block:: text

                  +----------------------------------------------+
     a   ========>|=============================================> |
      [W]         |                  +---------------------+     |
     b   ===|~|==>|=================>|        adder        |     |
      [W]         |                  |  SIGNED, SATURATE=0 |     |
  borrow_in -|~|->|=================>|                     |     |
                  |                  +---------------------+     |
                  |                   |        |         |       |
                  |        raw_difference   carry_out  overflow  |
                  |            |               |         |       |
                  |            |               v         |       |
                  |            |             [~] --------|-----> |--> borrow_out
                  |            |               |         |       |
                  |            v               v         v       |
                  |   +-------------------------------------+    |
                  |   | saturate: 0 if unsigned borrow      |    |
                  |   |           limits if signed overflow |    |
                  |   +-------------------------------------+    |
                  |            |                   |             |
                  +------------|-------------------|-------------+
                               v                   v
                           difference           overflow
                              [W]        (signed: adder, unsigned: borrow)

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
     - Operand and result width.
   * - ``SIGNED``
     - ``int unsigned``
     - 0
     - 0 or 1
     - Two's complement interpretation. Selects the overflow rule and the
       saturation limits; the difference itself is unaffected.
   * - ``SATURATE``
     - ``int unsigned``
     - 0
     - 0 or 1
     - Clamp an unrepresentable result instead of wrapping.

Illegal parameter values are rejected at elaboration with ``$fatal``.

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
     - Minuend.
   * - ``b``
     - in
     - ``WIDTH``
     - Subtrahend.
   * - ``borrow_in``
     - in
     - 1
     - Borrow into the least significant bit. Used as a minus one, and as the
       chaining input when several subtractors are cascaded.
   * - ``difference``
     - out
     - ``WIDTH``
     - Result. Saturated when ``SATURATE`` is set and the result was not
       representable, truncated otherwise.
   * - ``borrow_out``
     - out
     - 1
     - The result went below zero, read as an unsigned subtraction. Always
       meaningful, in both interpretations.
   * - ``overflow``
     - out
     - 1
     - The result was not representable under the selected interpretation.
       Unsigned, this is ``borrow_out``; signed, it is the sign-disagreement
       condition.

Usage examples
==============

A decay that stops at zero
--------------------------

The unsigned saturating configuration is the one that makes this block worth
instantiating rather than writing ``level - decay`` inline: the clamp is to
zero, which is what a level, a credit counter or a remaining-bytes field
needs, and which a plain subtraction gets catastrophically wrong by wrapping
to all-ones.

.. code-block:: systemverilog

   subtractor #(
     .WIDTH    (16),
     .SIGNED   (0),
     .SATURATE (1)
   ) u_decay (
     .a          (level),
     .b          (decay),
     .borrow_in  (1'b0),
     .difference (next_level),
     .borrow_out (floor_reached),
     .overflow   ()
   );

A wider subtractor from two narrower ones
-----------------------------------------

``borrow_out`` of the low half drives ``borrow_in`` of the high half.

.. code-block:: systemverilog

   subtractor #(.WIDTH (32), .SIGNED (0)) u_lo (
     .a (a[31:0]), .b (b[31:0]), .borrow_in (1'b0),
     .difference (diff[31:0]), .borrow_out (mid_borrow), .overflow ()
   );

   subtractor #(.WIDTH (32), .SIGNED (1)) u_hi (
     .a (a[63:32]), .b (b[63:32]), .borrow_in (mid_borrow),
     .difference (diff[63:32]), .borrow_out (), .overflow (overflow)
   );

Integration notes
-----------------

* ``borrow_out`` is the unsigned "went below zero" signal and is meaningful in
  both modes. In signed mode it is **not** an overflow indication — use
  ``overflow``.
* The borrow chain is the longest path in the block and its delay grows with
  ``WIDTH``. Register the result in the surrounding pipeline.
* With ``SATURATE`` off the block wraps, which is correct for a counter and
  wrong for a level or a credit. The parameter exists so that choice is
  visible at the instantiation.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_subtractor.py``
     - Identities, the borrow boundary, the signed overflow corners, the
       saturation limits — including the unsigned clamp to zero that the
       adder cannot supply — corner-biased randomised operands, operands
       forced into the opposite-sign arrangement where signed overflow lives,
       an exhaustive sweep at narrow widths, a borrow-chain regression, a
       cross-check against the equivalent addition, and a check that the
       result depends only on the present inputs.
   * - ``tb/tb_subtractor.sv``
     - Portable self-checking testbench: the directed corners, an exhaustive
       sweep at ``WIDTH=8`` and randomised vectors.
   * - ``formal/subtractor_formal.sv``
     - Exhaustive equivalence proof at ``WIDTH=16``: all four
       configurations against the borrow, overflow and saturation rules
       written as integer arithmetic on a wider difference.

Both reference models compute the exact difference in an arithmetic wider than
the design uses and then ask whether the value was representable. They share
none of the design's inverted-operand reasoning, which is what allowed them to
catch the inverted unsigned ``overflow`` flag rather than reproducing it.

.. code-block:: bash

   ctest --test-dir build -R 'subtractor'

Timing
======

The block is registered with ``NO_STA``: it is combinational, so there is no
setup or hold check to make on it in isolation. Its delay is one adder delay
plus the saturation multiplexer, and it is covered by the timing analysis of
the sequential blocks that instantiate it.
