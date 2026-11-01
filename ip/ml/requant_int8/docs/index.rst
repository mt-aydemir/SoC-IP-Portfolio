.. _ip-requant_int8:

=============
requant_int8
=============

Quantised-neural-network requantisation: a wide integer accumulator back down
to an int8 activation, with a per-channel bias, a fixed-point scale, round to
nearest and a saturating clamp.

Functional description
======================

A quantised convolution accumulates int8 products into a 32-bit total. That
total is expressed in the scale ``S_a * S_w`` — the product of the activation
and weight scales — and the next layer wants its input in the scale
``S_out``. Converting between them is a multiply by the real number
``(S_a * S_w) / S_out``, which is what this block performs:

.. code-block:: text

   out = clamp( round( (acc + bias) * mult / 2**shift ) + out_zero_point,
                out_min, out_max )

``mult`` and ``shift`` together are the fixed-point representation of that
real scale. The host picks them; the usual choice normalises ``mult`` into the
top octave of its range, which puts the most significant bits of the scale to
work and makes the shift the only thing that varies between channels by much.

Why the parameters are inputs
-----------------------------

``bias``, ``mult`` and ``shift`` are ports rather than parameters because
every output channel of a layer has its own. Per-channel quantisation is the
normal case rather than an optimisation: sharing one scale across a whole
layer costs real accuracy, and on depthwise convolutions — where each channel
has its own filter and its own dynamic range — it costs a great deal.

In the accelerator each column of the systolic array owns one output channel
and one instance of this block, and the parameters arrive with the job.

Rounding
--------

Round to nearest, ties away from zero, applied **once** to the full-width
product.

The implementation is an identity worth knowing. An arithmetic right shift
floors. Adding ``half`` before the shift turns it into round-half-up, which is
correct for positive values and off by one at the ties of negative ones.
Adding ``half - 1`` instead when the value is negative gives ties away from
zero:

.. code-block:: text

   shift = 2, half = 2

   product   +adjust   >>2   result      (exact value)
   ------------------------------------------------------
        5      5+2=7     1       1        1.25 -> 1
        6      6+2=8     2       2        1.5  -> 2   tie, away from zero
       -5     -5+1=-4   -1      -1       -1.25 -> -1
       -6     -6+1=-5   -2      -2       -1.5  -> -2  tie, away from zero

A shift of zero must add nothing at all: the negative adjustment is
``half - 1``, which is ``-1`` when ``half`` is zero, and applying it would
drag every negative result down by one.

This is the same rule as gemmlowp's ``RoundingDivideByPOT``. Reference
implementations in the TFLite lineage reach the result in two steps — a
doubling high multiply that rounds, then a rounding shift — and therefore
round twice. Rounding once on the full product is at least as accurate, but it
means a result here can differ from such a reference by one least significant
bit. The C driver that ships with the accelerator computes its expected values
the same way this block does, so the two agree exactly.

Zero points
-----------

Only the *output* zero point appears here. The input zero point of an
asymmetrically quantised activation is folded into ``bias`` by the host, using

.. code-block:: text

   sum_k w[k] * (a[k] - z_a)  =  sum_k w[k] * a[k]  -  z_a * sum_k w[k]

The correction term depends only on the weights, so the host computes it once
when it prepares a layer and adds it to the bias. That is what allows the
datapath in front of this block to be purely signed int8 with no zero-point
subtraction per multiply — a subtraction that would otherwise sit in the
critical path of all 256 elements of the array.

Fused activation
----------------

ReLU is not a mode. A fused ReLU is expressed by raising ``out_min`` to the
output zero point, and ReLU6 by additionally lowering ``out_max`` to the
quantised value of six. That is how a quantised graph represents a fused
activation, and it costs nothing here because the clamp exists anyway for
saturation.

``saturated`` reports that a particular result was clipped. Under a fused ReLU
that is the normal case rather than an error, but on a layer with no fused
activation a stream of saturations means the scales are wrong, and it is
cheaper to notice that on the first inference than in the accuracy numbers.

Block diagram
=============

.. code-block:: text

   acc  ---->(+)---->[reg]---->( x )---->[reg]--+
              ^                  ^              |
   bias ------+                  |              v
                          mult --+     +------------------+
                                       | + half           |
                                       | (or half-1 when  |
                                       |  negative)       |
                                       +--------+---------+
                                                |
                                       shift -->[ >>> ]
                                                |
                       out_zero_point -------->(+)
                                                |
              out_min, out_max ---------->[ clamp ]---->[reg]----> out_data
                                                |                   saturated
                                                +-----------------> out_valid

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
   * - ``ACC_WIDTH``
     - ``int unsigned``
     - 32
     - >= 4
     - Accumulator and bias width, two's complement.
   * - ``MULT_WIDTH``
     - ``int unsigned``
     - 24
     - >= 2
     - Fixed-point multiplier width, unsigned. 24 bits is around seven decimal
       digits of scale precision, which is far more than an int8 output can
       resolve.
   * - ``SHIFT_WIDTH``
     - ``int unsigned``
     - 6
     - >= 1
     - Width of the shift amount. The shift must stay below
       ``ACC_WIDTH + MULT_WIDTH + 2``, which an assertion checks.
   * - ``OUT_WIDTH``
     - ``int unsigned``
     - 8
     - 2 to ``ACC_WIDTH``
     - Output, zero point and clamp width, two's complement.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 22 8 18 52

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk`` / ``rst_n``
     - in
     - 1
     - Clock and active-low reset.
   * - ``in_valid``
     - in
     - 1
     - The operands and parameters on this cycle are a real job. There is no
       ready: the block never stalls.
   * - ``acc``
     - in
     - ``ACC_WIDTH``
     - Accumulator, two's complement.
   * - ``bias``
     - in
     - ``ACC_WIDTH``
     - Per-channel bias, two's complement, with the input zero-point
       correction already folded in.
   * - ``mult``
     - in
     - ``MULT_WIDTH``
     - Fixed-point scale numerator, unsigned.
   * - ``shift``
     - in
     - ``SHIFT_WIDTH``
     - Right shift applied after the multiply, unsigned.
   * - ``out_zero_point``
     - in
     - ``OUT_WIDTH``
     - Added after the shift, two's complement.
   * - ``out_min`` / ``out_max``
     - in
     - ``OUT_WIDTH``
     - Inclusive clamp window. Also carries a fused activation.
   * - ``out_valid``
     - out
     - 1
     - ``in_valid`` delayed by the pipeline latency.
   * - ``out_data``
     - out
     - ``OUT_WIDTH``
     - Requantised result, two's complement.
   * - ``saturated``
     - out
     - 1
     - This result was clipped by the window.

Usage examples
==============

Deriving mult and shift on the host
-----------------------------------

.. code-block:: c

   /* scale = (s_activation * s_weight) / s_output, a positive real below 1
      for any sane layer. Normalise it into the top octave of the multiplier
      so no precision is thrown away. */
   void requant_params(double scale, uint32_t *mult, uint8_t *shift)
   {
       int exponent = 0;
       double normalised = frexp(scale, &exponent);   /* 0.5 <= n < 1.0 */

       *mult  = (uint32_t)lround(normalised * (double)(1u << MULT_WIDTH));
       *shift = (uint8_t)(MULT_WIDTH - exponent);
   }

One instance per output channel
-------------------------------

.. code-block:: systemverilog

   for (genvar m = 0; m < COLS; m++) begin : g_requant
     requant_int8 #(
       .ACC_WIDTH (32), .MULT_WIDTH (24), .SHIFT_WIDTH (6), .OUT_WIDTH (8)
     ) u_requant (
       .clk (clk), .rst_n (rst_n),
       .in_valid       (column_valid),
       .acc            (column_acc[m]),
       .bias           (bias_q[m]),
       .mult           (mult_q[m]),
       .shift          (shift_q[m]),
       .out_zero_point (out_zero_point_q),
       .out_min        (out_min_q),
       .out_max        (out_max_q),
       .out_valid      (result_valid[m]),
       .out_data       (result_data[m]),
       .saturated      (result_saturated[m])
     );
   end

Integration notes
-----------------

* The block is a fixed three-cycle pipeline with no back-pressure. Whatever
  consumes it must always be able to accept a result, which in the
  accelerator is guaranteed by not admitting work unless there is already room
  for its result.
* Placing the requantisation at the bottom of each array column rather than
  after the output deskew is what keeps the deskew registers eight bits wide
  instead of thirty-two. For a 16-column array that is the difference between
  about 960 and about 3800 flip-flops.
* The multiply is the long path. It is one DSP block on an FPGA for the widths
  above; if the target period is tight, splitting stage 2 into two is the
  cheapest fix and costs one cycle of latency.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_requant_int8.py``
     - Reset state; measured pipeline latency; exact power-of-two scales; the
       rounding rule at every tie of both signs, with two values additionally
       hand-computed so a model that agreed with a broken design would still
       be caught; a shift of zero; both clamp edges and the values either side
       of them; a fused ReLU expressed through ``out_min``; a zero multiplier;
       4000 corner-biased random parameter sets; 2000 more drawn from the
       ranges a real quantised layer produces; 600 results at one per cycle
       with every parameter changing on each beat; and gaps in the input
       stream producing gaps in the output stream. Every check is an equality.
   * - ``tb/tb_requant_int8.sv``
     - Portable self-checking smoke test with a 64-bit reference model and
       3000 randomised beats.

.. code-block:: bash

   ctest --test-dir build -R 'requant_int8'
