.. _ip-barrel_shifter:

==============
barrel_shifter
==============

Combinational barrel shifter: logical and arithmetic shifts and rotates, in
either direction, by any amount in one cycle.

Functional description
======================

The block applies one of five operations to ``data_in`` by ``amount`` bit
positions and presents the result on ``data_out`` in the same cycle. The
operation is selected by a three-bit opcode.

A barrel shifter is a tree of multiplexer stages, one per bit of the shift
amount: stage *k* either passes its input through or shifts it by 2\ :sup:`k`.
That structure is what makes the delay logarithmic in ``WIDTH`` rather than
linear, and it is what ``<<``, ``>>`` and ``>>>`` infer on every synthesiser
worth using.

The operators are therefore used directly rather than building the mux tree by
hand. A hand-built tree would be larger, slower and harder to read, and would
defeat any target with a dedicated shifter. The one place the structure is
written out explicitly is the rotate, and only because a rotate is not a
single operator.

Operations
----------

.. list-table::
   :header-rows: 1
   :widths: 10 24 66

   * - Code
     - Operation
     - Behaviour
   * - 0
     - ``SHIFT_LEFT``
     - Zeros shifted in at the bottom.
   * - 1
     - ``SHIFT_RIGHT``
     - Zeros shifted in at the top; a logical shift.
   * - 2
     - ``ARITH_RIGHT``
     - The sign bit replicated at the top, so the value is divided by a power
       of two under a two's complement interpretation.
   * - 3
     - ``ROTATE_LEFT``
     - Bits leaving the top re-enter at the bottom.
   * - 4
     - ``ROTATE_RIGHT``
     - Bits leaving the bottom re-enter at the top.
   * - 5–7
     - *unused*
     - ``data_in`` passed through unchanged.

An arithmetic *left* shift is deliberately absent: it is identical to a
logical left shift, and offering both would suggest a difference that does not
exist.

The three unused encodings are specified as a pass-through rather than left to
chance. A ``case`` without a default is how a combinational block grows an
inferred latch, and an undefined opcode is exactly the condition under which
an integrator most needs a predictable result.

Rotates
-------

A rotate is built as the OR of the two halves of a double-width shift:

.. code-block:: text

   rotate_left(d, r)  == (d << r) | (d >> (WIDTH - r))
   rotate_right(d, r) == (d >> r) | (d << (WIDTH - r))

Building it that way rather than as a separate structure lets synthesis share
the mux tree with the plain shifts, so the five operations cost one shifter
and some multiplexing rather than two shifters.

The ``r == 0`` case is handled separately, because the expression above would
otherwise ask for a shift by the full width, which the mux structure does not
express.

Shift amount
------------

The amount is ``$clog2(WIDTH)`` bits wide, so every representable amount is in
range for a power-of-two ``WIDTH`` — the configuration the block is verified
in. For a non-power-of-two ``WIDTH`` the encoding can express amounts of
``WIDTH`` or more, and those are defined as follows:

* **shifts** produce the fully shifted result — all zeros, or all sign bits
  for the arithmetic right shift;
* **rotates** reduce the amount modulo ``WIDTH``, which is the only definition
  that keeps a rotate reversible.

Block diagram
=============

.. code-block:: text

                  +-------------------------------------------------+
   data_in =====>|=======+=========+==========+===================> |
      [W]        |       |         |          |                     |
                 |       v         v          v                     |
                 |  +---------+ +------+ +---------+                |
   amount  ----->|  |   <<    | |  >>  | |   >>>   |                |
   [clog2 W]     |  +---------+ +------+ +---------+                |
                 |       |         |          |                     |
                 |       |    +----+----+     |                     |
                 |       |    | rotate  |     |    (shares the tree) |
                 |       |    |  l | r  |     |                     |
                 |       |    +----+----+     |                     |
                 |       |      |    |        |                     |
                 |       v      v    v        v                     |
                 |   +------------------------------------+          |
   operation --->|   |          5-to-1 select             |=========>|==> data_out
      [3]        |   |   unused codes -> data_in          |          |      [W]
                 |   +------------------------------------+          |
                 +-------------------------------------------------+

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
     - Data width, and through ``$clog2(WIDTH)`` the width of the amount
       port. The lower bound is 2 because a one-bit shifter has nothing to
       shift.

Illegal parameter values are rejected at elaboration with ``$fatal``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 10 20 54

   * - Signal
     - Dir
     - Width
     - Description
   * - ``data_in``
     - in
     - ``WIDTH``
     - Data to shift or rotate.
   * - ``amount``
     - in
     - ``$clog2(WIDTH)``
     - Number of bit positions. Every value is legal; see *Shift amount* for
       what the out-of-range encodings mean at a non-power-of-two width.
   * - ``operation``
     - in
     - 3
     - Operation select. Codes 5 to 7 pass the data through.
   * - ``data_out``
     - out
     - ``WIDTH``
     - Result, available in the same cycle.

Usage examples
==============

Fixed-point scaling
-------------------

An arithmetic right shift divides by a power of two under a two's complement
interpretation, which is the normal way to rescale a fixed-point value.

.. code-block:: systemverilog

   barrel_shifter #(
     .WIDTH (32)
   ) u_rescale (
     .data_in   (accumulator),
     .amount    (fractional_bits),
     .operation (3'd2),             // ARITH_RIGHT
     .data_out  (rescaled)
   );

A rotating CRC or scrambler tap
-------------------------------

.. code-block:: systemverilog

   barrel_shifter #(.WIDTH (16)) u_rotate (
     .data_in   (state),
     .amount    (4'd3),
     .operation (3'd3),             // ROTATE_LEFT
     .data_out  (rotated_state)
   );

Integration notes
-----------------

* The shifter is a logarithmic mux tree, so its delay grows with
  ``$clog2(WIDTH)`` rather than with ``WIDTH``. It is nevertheless several
  levels of logic, and a shifter in series with an adder in one cycle is a
  common critical path. Register between them.
* Drive ``operation`` from a decoded constant or a registered field, not from
  a wide combinational decode in the same cycle: the opcode selects the final
  multiplexer, so its arrival time adds directly to the result's.
* At a non-power-of-two ``WIDTH``, read *Shift amount* before relying on an
  amount of ``WIDTH`` or more. The behaviour is defined, but it is defined
  differently for shifts and for rotates.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_barrel_shifter.py``
     - A shift of zero for every operation, including the rotates' explicit
       zero case; the smallest non-trivial amount; arithmetic right-shift sign
       extension across the full amount range; the pass-through opcodes;
       corner-biased randomised vectors; an exhaustive sweep of every
       ``(operation, amount)`` pair; a single-bit walk through every position
       and amount; and the rotate round-trip and population-count identities.
   * - ``tb/tb_barrel_shifter.sv``
     - Portable self-checking testbench: the directed cases, an exhaustive
       sweep of every operation, amount and data value at ``WIDTH=8``, the
       rotate round trip and randomised vectors.
   * - ``formal/barrel_shifter_formal.sv``
     - Exhaustive equivalence proof at ``WIDTH=16`` and ``WIDTH=12``,
       out-of-range amounts included, against a bit-at-a-time reference.

The two properties that carry the most weight are the ones that need no model
at all. A **single-bit walk** makes the result of every operation a single
known position, so a mux stage wired to the wrong power of two moves the bit
somewhere unpredicted — any denser data pattern can mask that by having a bit
there already. A **rotate round trip** proves no information is lost, which is
the one thing that distinguishes a rotate from a shift and the thing an
implementation that drops the wrapped bits gets wrong while passing every
directed case whose dropped bits happen to be zero.

.. code-block:: bash

   ctest --test-dir build -R 'barrel_shifter'

Timing
======

The block is registered with ``NO_STA``: it is combinational, so there is no
setup or hold check to make on it in isolation. Its delay is
``$clog2(WIDTH)`` multiplexer levels plus the operation select, and it is
covered by the timing analysis of the sequential blocks that instantiate it —
``alu`` among them.
