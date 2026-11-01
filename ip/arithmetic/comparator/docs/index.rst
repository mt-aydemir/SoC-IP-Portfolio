.. _ip-comparator:

==========
comparator
==========

Parameterised combinational magnitude comparator producing all six relational
results at once, signed or unsigned.

Functional description
======================

The block compares two operands and emits every relation between them:
equality, inequality, and the four orderings.

All six are produced together because they share almost all of their logic. A
single subtraction settles every relation, and the outputs are then a handful
of gates on its result. Emitting them separately would cost six comparators
where one is enough, and a synthesiser cannot always recognise that six
comparisons came from the same pair of operands. Callers that need only one
relation lose nothing: the unused outputs have no load, so the gates behind
them are removed.

Signed and unsigned
-------------------

Equality is interpretation-independent — two bit patterns are equal or they
are not, and nothing about ``SIGNED`` changes that. Ordering is not: ``0xFF``
is 255 unsigned and −1 signed, so it is the largest representable value or the
smallest, according only to how it is read.

Getting this wrong is one of the most common defects in hand-written
comparison logic, which is why the interpretation is a parameter here rather
than something the caller is expected to arrange around a fixed comparator.

The implementation avoids the trap that makes the mistake so easy to make.
The two orderings are written as two explicitly typed comparisons selected by
a generate, rather than as one comparison on a conditionally signed value:
SystemVerilog makes an expression unsigned if *any* of its operands is
unsigned, so a single comparison written to "work for both" silently becomes
the unsigned one and the signed configuration is quietly wrong.

Block diagram
=============

.. code-block:: text

                  +-----------------------------------------------+
     a   ========>|                                               |
      [W]         |   +-------------+                             |
                  |   |   a == b    |---------------------------> |--> equal
     b   ========>|   +-------------+       +-----+               |
      [W]         |          |------------->| not |-------------> |--> not_equal
                  |                         +-----+               |
                  |   +--------------------------------------+    |
                  |   | generate: SIGNED ? signed comparison |    |
                  |   |                  : unsigned one      |    |
                  |   +--------------------------------------+    |
                  |         |                        |            |
                  |         |----------------------------------> |--> less
                  |         |                        |----------> |--> greater
                  |         v                        v            |
                  |   +-----------+            +-----------+      |
                  |   | less|equal|----------> |greater|eq |----> |--> less_equal
                  |   +-----------+            +-----------+      |    greater_equal
                  +-----------------------------------------------+

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
     - >= 1
     - Operand width. A one-bit comparator is legal and meaningful here,
       unlike in the adder: equality and unsigned ordering are both defined.
   * - ``SIGNED``
     - ``int unsigned``
     - 0
     - 0 or 1
     - Interpret both operands as two's complement. Affects the four ordering
       outputs only; equality is unchanged.

Illegal parameter values are rejected at elaboration with ``$fatal``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 20 10 12 58

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
   * - ``equal``
     - out
     - 1
     - ``a == b``. Independent of ``SIGNED``.
   * - ``not_equal``
     - out
     - 1
     - ``a != b``. Independent of ``SIGNED``.
   * - ``less``
     - out
     - 1
     - ``a < b`` under the selected interpretation.
   * - ``less_equal``
     - out
     - 1
     - ``a <= b``, formed as ``less | equal``.
   * - ``greater``
     - out
     - 1
     - ``a > b`` under the selected interpretation.
   * - ``greater_equal``
     - out
     - 1
     - ``a >= b``, formed as ``greater | equal``.

Properties
----------

Two properties hold for every input pair and are the ones worth checking,
because they can be verified without knowing the right answer:

**Trichotomy.** Exactly one of ``less``, ``equal`` and ``greater`` is asserted
at any time. An implementation that mixes interpretations can report both
``less`` and ``greater`` for the same pair, and this is the check that catches
it. The RTL carries it as a concurrent assertion, so an integrator who
misconfigures the block sees the violation in their own simulation rather than
in a downstream symptom.

**Antisymmetry.** Swapping the operands mirrors the relations: ``a < b`` must
equal ``b > a`` for every pair. A comparator that grows a separate path for
each direction — which is what hand-written comparison logic tends to become
— fails this and nothing else.

Usage examples
==============

Threshold detection
-------------------

.. code-block:: systemverilog

   comparator #(
     .WIDTH  (12),
     .SIGNED (1)
   ) u_limit (
     .a             (measurement),
     .b             (threshold),
     .equal         (),
     .not_equal     (),
     .less          (),
     .less_equal    (),
     .greater       (over_threshold),
     .greater_equal ()
   );

Sorting network element
-----------------------

.. code-block:: systemverilog

   comparator #(.WIDTH (16), .SIGNED (1)) u_cmp (
     .a (x), .b (y),
     .equal (), .not_equal (), .less (x_smaller),
     .less_equal (), .greater (), .greater_equal ()
   );

   assign lo = x_smaller ? x : y;
   assign hi = x_smaller ? y : x;

Integration notes
-----------------

* Leave unused outputs unconnected rather than instantiating a narrower
  comparator. The logic behind an unloaded output is removed, and keeping one
  instantiation means one place where the interpretation is stated.
* The comparison is a full-width subtraction, so its delay grows with
  ``WIDTH`` in the same way as the adder's. Register the result in the
  surrounding pipeline.
* ``SIGNED`` must match the interpretation used everywhere else in the
  datapath. The commonest integration bug is a signed datapath with an
  unsigned comparator in one branch of it, which works for all positive data
  and fails the first time a value goes negative.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_comparator.py``
     - Equality, the pairs whose ordering depends entirely on ``SIGNED``, the
       extremes of the range, adjacent values across the sign-bit boundary,
       corner-biased randomised operands, one-bit near-miss pairs,
       an exhaustive sweep at narrow widths, and the trichotomy and
       antisymmetry properties.
   * - ``tb/tb_comparator.sv``
     - Portable self-checking testbench: the directed corners, every adjacent
       pair, an exhaustive sweep at ``WIDTH=8`` and randomised vectors, with
       trichotomy checked on every vector.

Both reference models decode the operands into a wider integer once and then
compare ordinarily, which is a different route to the answer than the
design's. A signedness mistake would have to be made twice, in two different
forms, to be missed.

.. code-block:: bash

   ctest --test-dir build -R 'comparator'

Timing
======

The block is registered with ``NO_STA``: it is combinational, so there is no
setup or hold check to make on it in isolation. Its delay is one subtraction
plus a few gates, and it is covered by the timing analysis of the sequential
blocks that instantiate it.
