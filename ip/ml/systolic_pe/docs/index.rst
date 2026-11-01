.. _ip-systolic_pe:

===========
systolic_pe
===========

Weight-stationary processing element for an int8 systolic matrix-multiply
array: one multiply-accumulate per cycle with a double-buffered weight
register.

Functional description
======================

The element holds one weight and sees one activation per cycle. It adds the
product to the partial sum arriving from the north and hands the total to the
south, while passing the activation on to the east.

An array of these computes a matrix product with no interconnect other than
the wires between neighbours, which is the whole point of the systolic
arrangement: every signal is a register-to-register hop between adjacent
cells, so the array scales to hundreds of elements without the fanout of a
broadcast bus. The cost of that is latency — a result emerges only after data
has walked across the array — and the array wrapper is where that latency is
accounted for.

Weight double buffering
-----------------------

The weight path is two registers deep:

``w_shift_q``
   Part of the load chain. ``w_shift`` moves it by one cell.

``w_q``
   What the multiplier reads. ``w_commit`` copies the shift register into it.

The separation is what allows the next weight tile to be pushed through the
array while the current tile is still computing. Without it, loading weights
would cost as many idle cycles as the array is deep, on every tile — for a
16x16 array driven at one vector per cycle that is a sixteen-cycle bubble
between tiles, and a convolution layer is nothing but a long sequence of
tiles.

Shift direction
---------------

The chain runs south to north: ``w_in`` comes from the cell below,
``w_out`` goes to the cell above.

That direction is deliberate. It is the one which makes a host push weight
rows in their natural order — row 0 first — and have each row come to rest in
the row that owns it. A north-to-south chain would require the host to reverse
them, which is a standing invitation to an off-by-one that shows up only as
slightly wrong numbers rather than as an obvious failure.

Why there is no enable
----------------------

The element cannot be stalled. Back-pressure in an array of these is handled
by tagging data with a valid bit that travels alongside it, and by refusing
new work at the array boundary, not by gating the pipeline.

Two reasons. A clock enable on every cell of a 256-element array is a fanout
problem in its own right, and an enable on the multiply-accumulate prevents it
being absorbed into the DSP blocks of an FPGA target, which is where the
density comes from. Cycles with nothing to do carry a zero activation, which
contributes nothing to any partial sum.

Arithmetic
----------

Both operands are two's complement. The product needs ``2*DATA_WIDTH`` bits —
for eight-bit operands the single product that needs all sixteen is
``-128 * -128 = +16384`` — and is sign-extended to ``ACC_WIDTH`` before the
add. The explicit width cast in the RTL is what makes that correct; without
it the addition would be evaluated at the product width and the carry out of
the top product bit would be lost.

Block diagram
=============

.. code-block:: text

                        w_out (to the cell above)
                             ^
                             |
                     +-------+--------------------------+
                     |   w_shift_q  --w_commit-->  w_q  |
                     +-------+--------------------------+
                             ^                    |
                             | w_in               v
                   psum_in --+------------> ( x )-+
                     (from above)             ^   |
                             |                |   v
        a_in  ------------> [reg] --------> a_out (to the cell to the east)
       (from the west)                          |
                                                v
                                       psum_out = psum_in + w_q * a_in
                                          (to the cell below)

Timing diagram
==============

Loading a weight, then two multiply-accumulates. Note that the multiply in the
cycle of the commit still uses the old weight: the commit and the multiply
happen at the same edge, so the new value is visible to the next one.

.. code-block:: text

              .    .    .    .    .    .    .    .
   clk     __/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__
              .    .    .    .    .    .    .    .
   w_shift ___/‾‾‾‾‾\_______________________________
   w_in    ---< 3  >-------------------------------
   w_commit _______/‾‾‾‾‾\_________________________
              .    .    .    .    .    .    .    .
   a_in    -----------------< 5  >< 7  >-----------
   psum_in -----------------< 100>< 0  >-----------
              .    .    .    .    .    .    .    .
   psum_out ---------------------< 115>< 21 >------
                                    ^
                                    +-- 100 + 3*5, one cycle after the operands

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 22 16 12 16 34

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 8
     - 2 to 18
     - Activation and weight width, two's complement. Eight is the int8 case;
       the upper bound is where a single DSP block on a typical FPGA stops
       holding the multiply.
   * - ``ACC_WIDTH``
     - ``int unsigned``
     - 32
     - >= ``2*DATA_WIDTH``
     - Partial sum width. The array needs
       ``2*DATA_WIDTH + $clog2(ROWS)`` to hold a full column sum without
       wrapping; 32 leaves generous headroom for any practical array.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 18 8 20 54

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk`` / ``rst_n``
     - in
     - 1
     - Clock and active-low reset.
   * - ``w_shift``
     - in
     - 1
     - Advance the weight load chain by one cell.
   * - ``w_commit``
     - in
     - 1
     - Publish the staged weight to the multiplier. Takes priority over
       ``w_shift`` in the same cycle.
   * - ``w_in`` / ``w_out``
     - in / out
     - ``DATA_WIDTH``
     - Weight load chain, south to north. ``w_out`` is the staged weight.
   * - ``a_in`` / ``a_out``
     - in / out
     - ``DATA_WIDTH``
     - Activation, west to east. ``a_out`` is ``a_in`` delayed one cycle.
   * - ``psum_in`` / ``psum_out``
     - in / out
     - ``ACC_WIDTH``
     - Partial sum, north to south.
       ``psum_out <= psum_in + w_q * a_in``.

Usage examples
==============

One row of an array
-------------------

.. code-block:: systemverilog

   for (genvar m = 0; m < COLS; m++) begin : g_row
     systolic_pe #(
       .DATA_WIDTH (8),
       .ACC_WIDTH  (32)
     ) u_pe (
       .clk (clk), .rst_n (rst_n),
       .w_shift  (w_shift),
       .w_commit (w_commit),
       .w_in     (w_chain[k+1][m]),   // from the cell below
       .w_out    (w_chain[k][m]),
       .a_in     (a_chain[k][m]),
       .a_out    (a_chain[k][m+1]),
       .psum_in  (psum_chain[k][m]),
       .psum_out (psum_chain[k+1][m])
     );
   end

Integration notes
-----------------

* The element is a fixed one-cycle pipeline with no handshake. Whatever
  instantiates it owns the accounting: which cycles carry real data, and when
  the results of those cycles emerge. ``systolic_array`` does that accounting.
* ``w_commit`` must not be asserted while activations belonging to the
  previous weight tile are still inside the array, or those vectors finish
  their accumulation against a mixture of two tiles. The array wrapper
  enforces this by draining before it commits.
* On an FPGA the multiply-accumulate maps to one DSP block per element with no
  vendor primitive in the source. On UltraScale+ the DSP48E2 can hold two
  eight-bit multiplies, so a vendor-specific variant could halve the DSP count;
  that optimisation is deliberately not taken here, because it would tie the
  block to one family.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_systolic_pe.py``
     - Reset state; a single multiply-accumulate; the activation hand-off east
       checked over the operand extremes; the weight shift chain; the double
       buffer, proving a staged weight has no arithmetic effect until it is
       committed; the signed extremes including ``DATA_MIN * DATA_MIN``; 2000
       corner-biased random operand triples against a Python model; a
       sustained 500-cycle stream with no bubbles; and a commit landing while
       data is in flight, which pins down the exact cycle a new weight takes
       effect.
   * - ``tb/tb_systolic_pe.sv``
     - Portable self-checking smoke test with 2000 randomised operand triples.

.. code-block:: bash

   ctest --test-dir build -R 'systolic_pe'
