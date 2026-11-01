.. _ip-systolic_array:

==============
systolic_array
==============

ROWS by COLS weight-stationary systolic array of int8 multiply-accumulate
elements, with the input skew and output deskew that turn it into a plain
vector-in, vector-out matrix multiplier.

Functional description
======================

The array computes one tile of a matrix product. With a weight tile ``W`` of
``ROWS`` by ``COLS`` held in the elements, presenting an activation vector
``a`` of ``ROWS`` values produces, ``LATENCY`` cycles later, the ``COLS``
element vector

.. code-block:: text

   res[m] = sum over k of  W[k][m] * a[k]

One vector may be presented on every cycle, and that is the point of the
structure: the array holds ``ROWS * COLS`` multipliers, and at one vector per
cycle it retires ``ROWS * COLS`` multiply-accumulates per cycle while moving
only one activation vector in and one result vector out. A 16 by 16 array at
250 MHz is 256 MACs per cycle, or 128 GOP/s counting a multiply and an add
separately, from 128 bits per cycle of activation bandwidth.

Skew and deskew
---------------

Inside the array an activation walks east one element per cycle while a
partial sum walks south one element per cycle. For the two to meet at the
element holding ``W[k][m]``, the activation of row ``k`` has to be launched
``k`` cycles after the activation of row 0.

That is the input skew: row ``k`` is delayed by ``k`` cycles.

.. code-block:: text

   time ->      0    1    2    3    4    5
   row 0     [a0]
   row 1          [a1]
   row 2               [a2]
   row 3                    [a3]

   the vector enters as a diagonal wavefront, and meets a partial-sum
   wavefront travelling south at the same speed

The consequence at the far end is that the column sums do not finish together
either — column ``m`` finishes ``m`` cycles after column 0 — so the output
deskew delays column ``m`` by ``COLS-1-m`` cycles to bring them back into
step. Together the two make the block present a flat latency of
``ROWS + COLS - 1`` rather than making its user think about wavefronts at all.

Both are triangular shift registers: ``ROWS*(ROWS-1)/2`` registers of
``DATA_WIDTH`` on the way in, and ``COLS*(COLS-1)/2`` of ``ACC_WIDTH`` on the
way out.

Where the deskew width comes from
---------------------------------

The deskew registers are ``ACC_WIDTH`` wide, and that is the one place this
partitioning costs area. Requantising at the bottom of each column *before*
the deskew would make them eight bits instead of thirty-two — for a 16 column
array, roughly 960 flip-flops instead of 3840.

The saving is real and is deliberately not taken. It would put a quantisation
policy inside a block whose job is arithmetic, and it would mean the array
could not be used for anything that wants its accumulators — a wider
reduction across several tiles, for instance, which is exactly what a
convolution with more than ``ROWS`` input channels needs. On the smallest
device the array fits at all, the difference is under 3% of the flip-flops.

Why there is no back-pressure
-----------------------------

The array cannot be stalled, and there is no ready signal. ``a_valid``
travels with the data so results emerge tagged, and cycles with no work
present a zero activation vector, which contributes nothing to any partial
sum. Gaps in the input stream are therefore free.

A user that cannot always accept a result must not present a vector.
``cnn_accel`` does this by refusing an activation unless its output buffer
already has room for the result that will arrive ``LATENCY`` cycles later,
which is a cheaper piece of logic than a stall network reaching every element
of the array would be.

Weight loading and the double buffer
------------------------------------

Weight rows enter at the south edge, one row per ``w_valid`` beat, and shift
northwards. Pushing rows in natural order — row 0 first — therefore leaves row
``k`` in row ``k`` after ``ROWS`` beats. Choosing that direction rather than
the other is worth a sentence: a north-to-south chain would require the host
to reverse the rows, and an off-by-one there produces numbers that are wrong
without being obviously wrong.

``w_commit`` publishes the whole tile at once, from the shadow register inside
each element. Because the shadow registers are not what the multipliers read,
the next tile can be pushed through the array while the current one is still
computing, and a layer made of many tiles pays no idle cycles for its weight
loads at all.

**A commit must not land while activations are still inside the array.** Those
vectors would finish their accumulation against a mixture of two tiles, giving
results that are wrong by an amount depending on how far each vector had
travelled — close to undebuggable from the outside. ``busy`` reports exactly
that condition, and an assertion fires if a commit arrives while it is high.

Block diagram
=============

.. code-block:: text

                      w_row (one row per beat, entering at the south edge)
                            ^        ^        ^
                            |        |        |
              0 --> +--------+--------+--------+
                    | PE 0,0 | PE 0,1 | PE 0,2 |  <-- a_skewed[0]
                    +--------+--------+--------+
                    | PE 1,0 | PE 1,1 | PE 1,2 |  <-- a_skewed[1]  (a[1] delayed 1)
                    +--------+--------+--------+
                    | PE 2,0 | PE 2,1 | PE 2,2 |  <-- a_skewed[2]  (a[2] delayed 2)
                    +---+----+---+----+---+----+
                        |        |        |
                        v        v        v
                     [ 2 regs ][ 1 reg ][ direct ]     output deskew
                        |        |        |
                        +--------+--------+
                                 |
                                 v
                            res_vector, all COLS columns in step

Timing diagram
==============

Two vectors admitted back to back into a 3 by 3 array, latency 5:

.. code-block:: text

              .    .    .    .    .    .    .    .
   clk     __/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__
              .    .    .    .    .    .    .    .
   a_valid ___/‾‾‾‾‾‾‾‾‾‾\_____________________________
   a_vector---< v0 >< v1 >-------------------------
              .    .    .    .    .    .    .    .
   busy    ___/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_______
              .    .    .    .    .    .    .    .
   res_valid_______________________/‾‾‾‾‾‾‾‾‾‾\_______
   res_vector----------------------< r0 >< r1 >-------
                                     ^
                                     +-- 5 cycles after v0 was admitted

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
   * - ``ROWS``
     - ``int unsigned``
     - 16
     - >= 2
     - Reduction depth, and the number of activations in a vector. Also the
       number of beats in a weight tile load.
   * - ``COLS``
     - ``int unsigned``
     - 16
     - >= 2
     - Output channels, and the number of results in a vector.
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 8
     - 2 to 18
     - Activation and weight width, two's complement.
   * - ``ACC_WIDTH``
     - ``int unsigned``
     - 32
     - >= ``2*DATA_WIDTH + $clog2(ROWS)``
     - Accumulator width, two's complement. The lower bound is checked at
       elaboration: it is what a full column sum needs before it can wrap.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 20 8 22 50

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk`` / ``rst_n``
     - in
     - 1
     - Clock and active-low reset.
   * - ``w_valid``
     - in
     - 1
     - This cycle's ``w_row`` is a weight row. ``ROWS`` beats load a tile.
   * - ``w_row``
     - in
     - ``COLS*DATA_WIDTH``
     - One weight row, column 0 in the low bits.
   * - ``w_commit``
     - in
     - 1
     - Publish the staged tile. Illegal while ``busy``.
   * - ``a_valid``
     - in
     - 1
     - This cycle's ``a_vector`` is real work. No ready: the array never
       stalls.
   * - ``a_vector``
     - in
     - ``ROWS*DATA_WIDTH``
     - Activation vector, row 0 in the low bits.
   * - ``res_valid``
     - out
     - 1
     - ``a_valid`` delayed by ``ROWS + COLS - 1``.
   * - ``res_vector``
     - out
     - ``COLS*ACC_WIDTH``
     - Result vector, column 0 in the low bits.
   * - ``busy``
     - out
     - 1
     - An admitted vector is still inside the pipeline.

Size and speed
==============

The structure fixes the register count exactly, so it can be stated before any
synthesis run. For the default 16 by 16, int8, 32-bit accumulator
configuration:

.. list-table::
   :header-rows: 1
   :widths: 46 22 32

   * - Element
     - Flip-flops
     - Note
   * - 256 processing elements
     - 14336
     - 56 each: two 8-bit weight registers, the activation register and the
       32-bit partial sum
   * - Input skew
     - 960
     - 120 registers of 8 bits
   * - Output deskew
     - 3840
     - 120 registers of 32 bits
   * - Valid delay line
     - 31
     - one per cycle of latency
   * - **Total**
     - **19167**
     -

The multiply-accumulate maps to one DSP block per element on an FPGA target —
256 of them for the default size, which fits comfortably on a ZU7EV and is
most of a ZU3EG. There is no vendor primitive in the source: the inference is
what puts it there.

The critical path is one multiply plus one add, independent of the array
dimensions. That is the property the systolic arrangement exists to provide,
and it is why enlarging the array costs area and latency but not frequency.

Usage examples
==============

A GEMM tile engine
------------------

.. code-block:: systemverilog

   systolic_array #(
     .ROWS (16), .COLS (16), .DATA_WIDTH (8), .ACC_WIDTH (32)
   ) u_array (
     .clk (clk), .rst_n (rst_n),
     .w_valid  (weight_beat), .w_row (weight_row), .w_commit (publish_tile),
     .a_valid  (admit), .a_vector (activation_vector),
     .res_valid (result_beat), .res_vector (result_vector),
     .busy (array_busy)
   );

   // Admit work only when there is already room for the result that will
   // arrive LATENCY cycles from now.
   assign admit = activation_available && output_credit_available;

   // And publish a new tile only once the array has drained.
   assign publish_tile = tile_staged && !array_busy;

Integration notes
-----------------

* The latency is ``ROWS + COLS - 1``. Anything that pairs per-channel state
  with a result — a bias, a requantisation multiplier — must be aligned to
  that number, or delayed alongside the data.
* ``a_valid`` and ``w_valid`` must not be asserted in the same cycle. It is
  harmless arithmetically, since the shadow registers are not read by the
  multipliers, but it is almost always a sign that the caller believes the
  array is idle when it is not. An assertion checks it.
* For a reduction deeper than ``ROWS``, run several tiles and add the result
  vectors outside the array. That is why the result is a full-width
  accumulator rather than a requantised value.
* The array is one clock domain. If the stream that feeds it is in another,
  cross with ``fifo_async`` outside this block.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_systolic_array.py``
     - Reset state; the measured latency; an identity tile, which is what makes
       a skew or deskew off by one visible directly; a hand-computed single
       vector; the signed extremes, including the largest column sum the array
       can produce; ``busy`` checked cycle by cycle across the whole pipeline;
       20 random tiles with 10 vectors each against a Python matrix multiply;
       a randomised batch with 30% idle cycles; 500 vectors at full rate; a
       tile loaded through the array *while* a batch is computing and published
       once it drains; and three consecutive tiles each with their own batch.
   * - ``tb/tb_systolic_array.sv``
     - Portable self-checking smoke test at 8 by 8: identity tile, the
       extremes, and 20 random tiles of 40 vectors with randomised gaps.

.. code-block:: bash

   ctest --test-dir build -R 'systolic_array'
