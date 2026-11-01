.. _ip-cnn_accel:

==========
cnn_accel
==========

Quantised int8 CNN inference accelerator: a systolic matrix-multiply array
with an output accumulator buffer and per-channel requantisation, driven
entirely over AXI4-Stream.

Functional description
======================

The block computes tiles of the matrix product that a convolution becomes once
it has been lowered to a GEMM. A host — on the reference platform a bare-metal
Cortex-A53 driving an AXI DMA — streams a weight tile, the requantisation
parameters and a batch of activation vectors, and receives a batch of int8
results.

Everything is a frame on the data stream. There is no register interface.

Why there is no register interface
----------------------------------

This is an architectural choice, not a shortcut.

A convolution layer is not one matrix multiply; it is dozens or hundreds of
tiles. If the accelerator were driven through control registers, the processor
would have to be involved between every one of them: write the descriptor,
start it, wait for the interrupt, write the next. At 250 MHz a tile of 256
vectors takes about a microsecond, and an interrupt round trip on a Cortex-A53
running bare metal is a comparable time — so the processor, not the array,
would set the layer's execution time.

With every command carried in the stream, an entire layer becomes one
scatter-gather descriptor chain. The DMA walks it to completion, the
accelerator parses the frames as they arrive, and the processor is untouched
from the start of the layer to the end of it. The only interrupt is the one
that says the layer is done.

The cost is that a malformed frame has no out-of-band recovery path, which is
why the parser is written to survive one — see `Error handling`_.

Frame format
------------

Every frame is a header beat followed by its payload, delimited by ``TLAST``.

.. code-block:: text

   header beat
     [ 7: 0]  opcode
     [ 9: 8]  flags        COMPUTE: bit 0 = first tile, bit 1 = last tile
     [15:10]  reserved
     [31:16]  count        payload beats the header claims
     [39:32]  out_zero_point    LOAD_PARAMS only, two's complement
     [47:40]  out_min           LOAD_PARAMS only, two's complement
     [55:48]  out_max           LOAD_PARAMS only, two's complement

.. list-table::
   :header-rows: 1
   :widths: 12 22 20 46

   * - Opcode
     - Command
     - Payload
     - Effect
   * - ``0x00``
     - ``NOP``
     - none
     - A fence, and the acknowledgement that clears the sticky error.
   * - ``0x01``
     - ``LOAD_WEIGHTS``
     - ``ARRAY_N`` beats
     - Beat ``k`` is weight row ``k``, byte ``m`` holding ``W[k][m]``.
       Published when the frame ends and the array has drained.
   * - ``0x02``
     - ``LOAD_PARAMS``
     - ``ARRAY_N`` beats
     - Beat ``m`` is channel ``m``'s ``{shift, mult, bias}``. The clamp window
       and output zero point come from the header.
   * - ``0x03``
     - ``COMPUTE``
     - ``count`` beats
     - Beat ``v`` is an activation vector. Emits a ``count``-beat result frame
       if the *last* flag is set.
   * - ``0x04``
     - ``STATUS``
     - none
     - Replies with a two-beat frame: geometry and flags, then the counters.

The status reply:

.. code-block:: text

   beat 0
     [ 7: 0]  version              [39:32]  flags: error, saturated, busy
     [15: 8]  ARRAY_N              [55:40]  ACC_DEPTH
     [23:16]  DATA_WIDTH           [63:56]  OUT_FIFO_DEPTH, saturated to 255
     [31:24]  ACC_WIDTH

   beat 1
     [31: 0]  completed jobs
     [63:32]  processed activation vectors

A requantisation parameter beat packs from the bottom, so it fits inside 64
bits for every legal configuration:

.. code-block:: text

   [ACC_WIDTH-1 : 0]                                    bias, two's complement
   [ACC_WIDTH+MULT_WIDTH-1 : ACC_WIDTH]                 mult, unsigned
   [ACC_WIDTH+MULT_WIDTH+SHIFT_WIDTH-1 : +MULT_WIDTH]   shift, unsigned

The accumulator buffer
----------------------

The array reduces over ``ARRAY_N`` terms. A real convolution layer reduces over
``kernel_h * kernel_w * input_channels``, which is routinely in the hundreds.
Something has to hold the partial sums between tiles.

Doing it on the host is not viable. It is ``ARRAY_N`` times less arithmetic
than the accelerator is doing — but on a scalar core rather than on 256
multipliers, so it becomes the bottleneck almost immediately, and it would mean
moving int32 partial sums across the bus instead of int8 results.

So results land in a buffer indexed by position within the batch, and each tile
adds into it:

.. code-block:: text

   COMPUTE flags       effect
   ----------------------------------------------------------------------
   first               overwrite the buffer instead of adding to it
   last                requantise and emit a result frame
   first and last      a layer whose reduction fits in a single tile
   neither             an interior tile: accumulate, emit nothing

The buffer bounds a batch to ``ACC_DEPTH`` vectors, which is what the host
tiles the output positions against. Every tile of one accumulation chunk must
present the same batch length — they index the same buffer — and a mismatch
raises the error rather than quietly adding one output position's partial sum
to a different one's.

The read-add-write cycle needs no hazard logic. Results leave the array in the
order their vectors were admitted, so the address is a counter; the read is
issued in the cycle a result appears and consumed in the next, which is also
when the sum is written back, so the read and the write are permanently one
address apart. The address only restarts at zero on the first admitted vector
of a frame, and a frame cannot start until the previous one has drained.

Flow control by credit
----------------------

The array and the requantiser are fixed-latency pipelines that cannot be
stalled. Rather than build a stall network reaching 256 elements, the block
refuses to admit an activation unless the output buffer already has room for
the result that will arrive ``TOTAL_LATENCY`` cycles later.

The accounting is one counter: vectors admitted, minus vectors that have
reached the far end. Admission needs ``fifo_level + inflight < OUT_FIFO_DEPTH``.

That is also why ``OUT_FIFO_DEPTH`` must exceed the pipeline latency, which an
elaboration check enforces. A shallower buffer deadlocks: no credit to admit
work, and no work in flight to release the credit.

Error handling
--------------

``TLAST`` is the delimiter and ``count`` is the check. Where they disagree,
``TLAST`` wins — it is what the DMA actually produced — and the mismatch raises
a sticky error. That is the difference between a driver bug that shows up as
one flagged job and one that shows up as every subsequent job being wrong.

.. list-table::
   :header-rows: 1
   :widths: 40 60

   * - Malformed frame
     - Behaviour
   * - Unknown opcode
     - Payload consumed and discarded, error raised. The parser stays in step.
   * - Weight frame too short or too long
     - **Not committed at all.** Half a tile is misaligned rather than merely
       incomplete — every row would sit in the wrong row of the array — so
       computing with it would give numbers that look almost right.
   * - Parameter frame the wrong length
     - Error raised; the beats that did arrive are applied.
   * - Compute frame shorter than its count
     - The vectors that arrived are computed and emitted as a well-formed
       frame, so the consumer's DMA still completes. Error raised.
   * - Compute frame longer than its count
     - Surplus beats dropped, error raised.
   * - Chunk tiles disagreeing on batch length
     - Error raised at the end of the offending frame.

``NOP`` clears the sticky error, and ``STATUS`` reports it along with the
geometry and the counters. Reading the geometry back is what makes a mismatch
between the bitstream and the software detectable at start-up: a driver that
assumes the wrong array size produces garbage rather than an error.

Block diagram
=============

.. code-block:: text

   s_axis ---> +--------------------+
               | cnn_accel_ctrl     |--- weight rows -----------+
               | frame parser       |                           |
               | credit and drain   |--- activation vectors --+ |
               | rules              |                         | |
               +---------+----------+                         v v
                         |                          +--------------------+
                         |                          |  systolic_array    |
                         |                          |  ARRAY_N x ARRAY_N |
                         |                          +---------+----------+
                         |                                    | ARRAY_N x ACC_WIDTH
                         |                                    v
                         |                          +--------------------+
                         |                          | accumulator buffer |
                         |                          | read - add - write |
                         |                          +---------+----------+
                         |                                    |
                         +--- requant parameters ---> +--------v-----------+
                                                      | ARRAY_N x          |
                                                      | requant_int8       |
                                                      +---------+----------+
                                                                | ARRAY_N x int8
                                                                v
                                                      +--------------------+
                                                      | fifo_sync + TLAST  |---> m_axis
                                                      +--------------------+

Timing diagram
==============

A single-tile layer, from the weight frame to the result frame:

.. code-block:: text

   s_axis  |HDR|w0 |w1 |...|w15|  |HDR|p0 |...|p15|  |HDR|a0 |a1 |a2 |...
   tlast   |   |   |   |   | X |  |   |   |   | X |  |   |   |   |   |
                                                          |
                                                          +-- admitted here
                                                              |
   m_axis                                                     +--(36 cycles)--> |r0 |r1 |...
   irq     ______________________________________________________________________________/‾\_
                                                                        the last beat leaves

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 24 14 12 16 34

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``ARRAY_N``
     - ``int unsigned``
     - 16
     - >= 8
     - Array dimension. The stream is ``ARRAY_N*DATA_WIDTH`` wide; the lower
       bound is what makes a 64-bit header and parameter beat fit.
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 8
     - 8
     - Activation, weight and output width. Fixed at 8: the header places the
       clamp values on byte boundaries.
   * - ``ACC_WIDTH``
     - ``int unsigned``
     - 32
     - >= 20
     - Accumulator width, in the array and in the buffer.
   * - ``MULT_WIDTH``
     - ``int unsigned``
     - 24
     - >= 2
     - Requantisation multiplier width.
   * - ``SHIFT_WIDTH``
     - ``int unsigned``
     - 6
     - >= 1
     - Requantisation shift width.
   * - ``ACC_DEPTH``
     - ``int unsigned``
     - 256
     - 2 to 65535
     - Accumulator buffer depth; the largest legal ``COMPUTE`` batch.
   * - ``OUT_FIFO_DEPTH``
     - ``int unsigned``
     - 64
     - > ``2*ARRAY_N + 4``
     - Output buffer depth. Must exceed the pipeline latency or the credit
       scheme deadlocks.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 24 8 22 46

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk`` / ``rst_n``
     - in
     - 1
     - Clock and active-low reset.
   * - ``s_axis_tvalid`` / ``tready`` / ``tdata`` / ``tlast``
     - —
     - 1 / 1 / ``ARRAY_N*8`` / 1
     - Command stream. Standard AXI4-Stream; no ``tkeep``, because every beat
       is a full word.
   * - ``m_axis_tvalid`` / ``tready`` / ``tdata`` / ``tlast``
     - —
     - 1 / 1 / ``ARRAY_N*8`` / 1
     - Result stream. One frame per emitting ``COMPUTE``, and one two-beat
       frame per ``STATUS``.
   * - ``irq``
     - out
     - 1
     - One-cycle pulse when an output frame's last beat is taken by the
       consumer — not when it was produced, so a host woken by it can read the
       whole result without a further check.
   * - ``error``
     - out
     - 1
     - Sticky protocol error. Cleared by ``NOP`` or reset.
   * - ``busy``
     - out
     - 1
     - A frame is being parsed, work is in flight, or results are unread.

Size and speed
==============

The register counts below follow from the structure, so they can be stated
before synthesis; the DSP and block RAM figures are what the structure implies
on an UltraScale+ target and should be confirmed against a real run.

.. list-table::
   :header-rows: 1
   :widths: 40 20 40

   * - Element
     - Flip-flops
     - Note
   * - ``systolic_array`` 16x16
     - 19167
     - 256 DSP blocks, one per element
   * - 16 x ``requant_int8``
     - ~2990
     - a 33 x 24 multiply each; two DSP blocks apiece on UltraScale+
   * - Requantisation parameters
     - 1016
     - 16 channels of bias, multiplier and shift
   * - Accumulator stage
     - ~1050
     - the registered result and its address
   * - Control and counters
     - ~200
     -
   * - **Total**
     - **~24400**
     - plus ~290 DSP and ~9 block RAMs

The accumulator buffer is 256 x 512 bits — 128 kbit, eight 36 kbit block RAMs
at that width — and the output buffer one more.

Throughput, measured in the cocotb regression on a 256-vector batch: **1.145
cycles per vector**, or 224 multiply-accumulates per cycle against a peak of
256. The gap is the header beat and the pipeline drain amortised over the
batch, and it shrinks as the batch grows. At 250 MHz that is about 56 G
multiply-accumulates per second, or 112 GOP/s counting the multiply and the add
separately.

Usage examples
==============

A single-tile layer
-------------------

.. code-block:: text

   LOAD_WEIGHTS  16 beats     the weight tile, row 0 first
   LOAD_PARAMS   16 beats     bias, multiplier and shift per output channel
   COMPUTE       T beats      first = 1, last = 1
   -> one result frame of T beats

A reduction over 64 input channels, four tiles deep
---------------------------------------------------

.. code-block:: text

   LOAD_PARAMS   16 beats     once for the whole chunk
   LOAD_WEIGHTS  16 beats     tile 0
   COMPUTE       T beats      first = 1, last = 0     no output
   LOAD_WEIGHTS  16 beats     tile 1
   COMPUTE       T beats      first = 0, last = 0     no output
   LOAD_WEIGHTS  16 beats     tile 2
   COMPUTE       T beats      first = 0, last = 0     no output
   LOAD_WEIGHTS  16 beats     tile 3
   COMPUTE       T beats      first = 0, last = 1
   -> one result frame of T beats

The weight frame of each tile is parsed while the previous tile's results are
still draining, so the only cost of splitting a reduction is the weight
bandwidth.

Integration notes
-----------------

* The block is one clock domain. On the reference Zynq UltraScale+ design it
  runs at 250 MHz off the PL clock, with the DMA in the same domain; if the
  stream arrives in another, cross it with ``fifo_async`` outside this block.
* ``irq`` is a one-cycle pulse in the accelerator's clock domain. Route it to
  the PS through the usual synchroniser, or ignore it and poll the DMA — the
  reference driver does the latter, because the DMA's own completion is the
  signal that the result is in memory rather than merely produced.
* The input zero point of an asymmetrically quantised activation is folded into
  the bias by the host; see ``requant_int8`` for the identity. Nothing in this
  block subtracts a zero point per multiply.
* A weight tile is ``ARRAY_N`` beats whatever the real reduction depth is. A
  host with fewer than ``ARRAY_N`` input channels left pads the tile with
  zeros, which contribute nothing.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_cnn_accel.py``
     - Reset state; the status reply, checked field by field; an identity layer
       that must return its input unchanged; a single-tile GEMM and a
       three-tile accumulation against a model of the whole datapath; a fused
       ReLU, with the test asserting that the stimulus actually reached the
       clamp; per-channel parameters, which a design latching one set for the
       layer would fail and nothing else would; the interrupt and the counters;
       eight random layers and four random multi-tile layers; result-stream
       back-pressure at 30% ready; a 256-vector batch with the cycles per
       vector measured and bounded; a batch that exactly fills the accumulator
       buffer; and five malformed frames — unknown opcode, short weight frame,
       compute count mismatch in both directions, and inconsistent chunk
       lengths — each followed by a good job to prove the parser stayed in step.
   * - ``tb/tb_cnn_accel.sv``
     - Portable self-checking smoke test at 8 by 8: identity layer, a random
       tile with per-channel scales, a three-tile reduction, a truncated weight
       frame that must be refused, and the ``NOP`` acknowledgement.

.. code-block:: bash

   ctest --test-dir build -R 'cnn_accel'
