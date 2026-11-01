.. _ip-mac_array:

=========
mac_array
=========

``LANES``-wide multiply-accumulate array: a pipelined dot-product engine that
multiplies ``LANES`` operand pairs per cycle, sums them through a registered
adder tree, and accumulates the sums over the beats of a vector.

Functional description
======================

What it computes
----------------

.. code-block:: text

   m_data = ( sum over beats, sum over lanes i of a[i] * b[i] ) mod 2**ACC_WIDTH

A vector is a sequence of beats, ``LANES`` operand pairs each, ended by
``s_last``. A fully connected layer, a 1x1 convolution or one output of a
larger convolution is a dot product of this kind: the vector length is the
reduction depth, and a length that is not a multiple of ``LANES`` is padded
with zero operands in the last beat.

Where it fits
-------------

``systolic_array`` holds a weight tile in place and computes a tile of dot
products at once; its weights are loaded once and reused for every
activation vector. This block takes both operands as streams and computes
one dot product at a time. It is the shape for layers with no weight reuse -
fully connected layers at batch size one, depthwise convolutions - where a
weight-stationary array would spend more cycles loading weights than
computing.

Operands
--------

``A_SIGNED`` and ``B_SIGNED`` choose two's complement or unsigned for each
operand. Each operand is extended by one bit - its sign bit, or a zero - and
one signed multiply of the extended values is exact for all four
combinations, so uint8 activations against int8 weights, the usual quantised
case, need no offset. Every product fits ``2*DATA_WIDTH + 1`` bits and every
beat's sum ``$clog2(LANES)`` more.

Accumulation
------------

The accumulator is ``ACC_WIDTH`` bits and wraps modulo ``2**ACC_WIDTH``, as
integer accumulators do in every quantised-inference runtime; the result is
exact whenever the true dot product fits. ``ACC_WIDTH`` must hold at least
one beat exactly. The result is the raw accumulator: scaling it to an
activation is ``requant_int8``'s job.

Pipeline
--------

.. code-block:: text

   stage 1                 LANES products, registered
   stages 2 .. L+1         adder tree, one registered level per stage
                           (L = $clog2(LANES); lanes padded to a power of two)
   stage L+2               accumulate; on s_last, push the total into the FIFO

The result is at the head of the output FIFO ``$clog2(LANES) + 2`` cycles
after the beat carrying ``s_last`` was accepted.

Flow control
------------

The pipeline never stalls. Every accepted last beat takes a credit, returned
when its result is taken, and ``s_ready`` is high while fewer than
``DEPTH = $clog2(LANES) + 3`` credits are out. The output FIFO is ``DEPTH``
entries deep, so it can never overflow, and ``DEPTH`` is exactly enough for
one beat per cycle with ``m_ready`` held high even when every beat ends a
vector.

``s_ready`` is a register compare. There is no combinational path from
``m_ready`` to ``s_ready``, and ``m_ready`` does not fan out to the pipeline.
The first version of this block stalled every pipeline register from
``m_ready``; that path missed timing at 5 ns on the portfolio library, and
the credit scheme replaced it at no cost in latency.

Block diagram
=============

.. code-block:: text

   s_a, s_b --> [x] x LANES --> [+] [+] ... --> [+] --> acc --> FIFO --> m_data
                 stage 1        tree levels             ^  |   (DEPTH)
                                                        +--+
   s_valid, s_last --> valid / last tags ----------------->  push

   credits: +1 per accepted last beat, -1 per result taken;  s_ready = credits < DEPTH

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
   * - ``LANES``
     - ``int unsigned``
     - 16
     - 1 to 64
     - Operand pairs per beat.
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 8
     - 2 to 16
     - Operand width.
   * - ``ACC_WIDTH``
     - ``int unsigned``
     - 32
     - ``2*DATA_WIDTH+1+$clog2(LANES)`` to 64
     - Accumulator and result width.
   * - ``A_SIGNED``
     - ``int unsigned``
     - 1
     - 0, 1
     - ``s_a`` lanes are two's complement (1) or unsigned (0).
   * - ``B_SIGNED``
     - ``int unsigned``
     - 1
     - 0, 1
     - ``s_b`` lanes likewise.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 22 8 18 52

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``, ``rst_n``
     - in
     - 1
     - Clock and active-low asynchronous reset.
   * - ``s_valid`` / ``s_ready``
     - in / out
     - 1
     - Beat handshake.
   * - ``s_a``, ``s_b``
     - in
     - ``LANES*DATA_WIDTH``
     - Operands; lane ``i`` is bits ``[i*DATA_WIDTH +: DATA_WIDTH]``.
   * - ``s_last``
     - in
     - 1
     - Last beat of the vector.
   * - ``m_valid`` / ``m_ready``
     - out / in
     - 1
     - Result handshake.
   * - ``m_data``
     - out
     - ``ACC_WIDTH``
     - The dot product.

Integration notes
-----------------

* Follow the block with ``requant_int8`` to turn the accumulator into an
  int8 activation; fold the input zero point into its bias.
* With signed activations against signed weights, set both ``*_SIGNED`` to
  1; nothing else changes.
* Area grows with ``LANES`` as ``LANES`` multipliers plus ``LANES - 1``
  adders; the FIFO and credits add ``DEPTH * ACC_WIDTH`` flip-flops.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_mac_array.py``
     - Every result against a model of the header's definition, and the
       random results also against ``numpy.dot``. The extreme products in
       every lane at once and in each lane alone; vectors of 1 to 10 beats;
       one beat per cycle and the exact latency; full rate with every beat
       a last beat; exactly ``DEPTH`` results accepted against a stalled
       sink; a waiting result; the accumulator wrapping; a reset
       mid-vector; random vectors under gaps and back-pressure. Run at
       seven parameter sets covering all four signedness combinations,
       ``LANES`` = 1, 3, 5, 16 and 64, and ``DATA_WIDTH`` = 4 to 16.
   * - ``tb/tb_mac_array.sv``
     - Five lanes (a padded tree), six-bit unsigned activations against
       signed weights, and the narrowest legal accumulator, so long vectors
       wrap: 3000 vectors of 1 to 40 beats against a 64-bit reference,
       with gaps and back-pressure.

.. code-block:: bash

   ctest --test-dir build -R 'mac_array'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration. The longest
register-to-register logic is the multiplier stage or the accumulator's
``ACC_WIDTH``-bit adder; each tree level is a single adder.
