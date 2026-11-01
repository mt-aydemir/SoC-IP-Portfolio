.. _ip-cdc_handshake:

=============
cdc_handshake
=============

Transfers a multi-bit value between clock domains with a four-phase handshake.

Functional description
======================

A multi-bit value must never cross a clock domain boundary through a bank of
synchronisers. Each bit resolves metastability independently, so the
destination can latch a combination that never existed at the source: a
four-bit counter stepping from ``0111`` to ``1000`` changes every bit at once
and can be observed as any of the sixteen possible values.

This block sidesteps the problem rather than mitigating it. **The data path
never crosses asynchronously at all.** Only two single-bit control signals are
synchronised — a request and an acknowledge — and the payload is held in a
source-domain register that is guaranteed stable throughout the window in which
the destination is permitted to read it. What the destination samples is a
static value, so there is nothing for metastability to corrupt.

The stability guarantee comes from one rule in the source state machine: the
payload register is written only in the ``SRC_IDLE`` state, and the request is
low in that state. From the moment the request rises until the source has seen
the acknowledge and returned to idle, the register cannot change.

Four-phase sequence
-------------------

#. **Request.** The source latches the payload and raises ``req``.
#. **Capture.** The destination sees ``req`` through a synchroniser, captures
   the payload and presents it on ``dst_valid`` / ``dst_data``.
#. **Acknowledge.** Once the destination consumer accepts the word, the
   destination raises ``ack``.
#. **Recovery.** The source sees ``ack`` and drops ``req``; the destination
   sees ``req`` fall and drops ``ack``; the source returns to idle.

The fourth phase is not ceremony. Without it, the next request could be
acknowledged by the trailing edge of the previous transfer, and the source
would believe a word had been delivered when it had not.

Choosing between the CDC blocks
-------------------------------

.. list-table::
   :header-rows: 1
   :widths: 45 55

   * - Situation
     - Block
   * - One independent status bit
     - ``cdc_sync_2ff``
   * - A single event with no payload
     - ``cdc_pulse_sync``
   * - Occasional value transfer, buffering not wanted
     - ``cdc_handshake``
   * - A continuous data stream
     - ``fifo_async``

A handshake pays the full round-trip latency on every word, so it is the wrong
choice for streaming. It costs two flip-flop chains and one register instead of
a dual-port memory, which is the right trade when transfers are rare.

Block diagram
=============

.. code-block:: text

    source domain (src_clk)        |     destination domain (dst_clk)
                                   |
   src_valid -->+-----------+      |      +-----------+<-- dst_ready
   src_ready <--|  source   |      |      |destination|--> dst_valid
                |   FSM     |      |      |    FSM    |
                | IDLE      |      |      | IDLE      |
                | REQUEST   |      |      | PRESENT   |
                | RECOVER   |      |      | ACK       |
                +-----+-----+      |      +-----+-----+
                      | req        |            ^ req_sync
                      |    +-------|--------+   |
                      +--->| sync_2ff (dst) |---+
                           +-------|--------+
                                   |
                           +-------|--------+
                      +----| sync_2ff (src) |<--+ ack
                      |    +-------|--------+   |
                      v ack_sync   |            |
                (back to source FSM)|
                                   |
   src_data ==>[ payload_q ]=======|=======> [ dst_data ]
                  [WIDTH]          |            [WIDTH]
                                   |
              written only while   |     captured while req_sync is high
              req is low           |     -> always a static value

Timing diagram
==============

One complete transfer. ``STAGES = 2``; the destination clock is slower:

.. code-block:: text

              .   .   .   .   .   .   .   .   .   .   .   .
   src_clk  _/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_
              .   .   .   .   .   .   .   .   .   .   .   .
   src_valid _/‾‾‾\_______________________________________
              .   .   .   .   .   .   .   .   .   .   .   .
   src_ready ‾‾‾‾‾\_______________________________/‾‾‾‾‾‾‾  closed for the
              .   .   .   .   .   .   .   .   .   .   .   .   whole round trip
   src_data  -< D >-------------------------------------
              .   .   .   .   .   .   .   .   .   .   .   .
   payload_q ____< D                                  >---  stable while req
              .   .   .   .   .   .   .   .   .   .   .   .
   req       ____/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\___________
              .   .   .   .   .   .   .   .   .   .   .   .
   dst_clk   __/‾‾‾‾‾\_____/‾‾‾‾‾\_____/‾‾‾‾‾\_____/‾‾‾‾‾\_
              .   .   .   .   .   .   .   .   .   .   .   .
   req_sync  ______________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_______
              .   .   .   .   .   .   .   .   .   .   .   .
   dst_valid ____________________/‾‾‾‾‾\_________________
              .   .   .   .   .   .   .   .   .   .   .   .
   dst_ready ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
              .   .   .   .   .   .   .   .   .   .   .   .
   dst_data  ------------------< D     >-----------------
              .   .   .   .   .   .   .   .   .   .   .   .
   ack       __________________________/‾‾‾‾‾‾‾‾‾\_______

Note that ``src_ready`` stays low for the entire round trip. A source that
reopened earlier would overwrite ``payload_q`` while the destination was still
reading it — precisely the corruption the handshake exists to prevent.

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 18 20 12 12 38

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 32
     - >= 1
     - Payload width. Costs one register of this width; the width has no
       effect on latency, because the payload does not cross asynchronously.
   * - ``STAGES``
     - ``int unsigned``
     - 2
     - >= 2
     - Depth of both synchroniser chains. Directly sets the round-trip latency
       and therefore the maximum transfer rate.

Both are checked at elaboration with ``$fatal``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 8 14 10 52

   * - Signal
     - Dir
     - Width
     - Domain
     - Description
   * - ``src_clk``
     - in
     - 1
     - src
     - Source clock. No relationship to ``dst_clk`` is assumed.
   * - ``src_rst_n``
     - in
     - 1
     - src
     - Source-domain reset, active low.
   * - ``src_valid``
     - in
     - 1
     - src
     - Source payload is valid.
   * - ``src_ready``
     - out
     - 1
     - src
     - The block will accept a word this cycle. Low for the whole round trip
       of a transfer already in flight.
   * - ``src_data``
     - in
     - ``DATA_WIDTH``
     - src
     - Source payload. Must be stable while stalled.
   * - ``dst_clk``
     - in
     - 1
     - dst
     - Destination clock.
   * - ``dst_rst_n``
     - in
     - 1
     - dst
     - Destination-domain reset, active low.
   * - ``dst_valid``
     - out
     - 1
     - dst
     - Destination payload is valid. Held until ``dst_ready``.
   * - ``dst_ready``
     - in
     - 1
     - dst
     - The consumer accepts a word this cycle.
   * - ``dst_data``
     - out
     - ``DATA_WIDTH``
     - dst
     - Destination payload, registered.

Both interfaces follow AXI4-Stream handshake semantics: a transfer occurs on
any rising edge where ``valid`` and ``ready`` are both high, ``valid`` may not
be withdrawn before the transfer completes, and ``ready`` may be withdrawn
freely.

Usage examples
==============

Crossing a configuration word
-----------------------------

.. code-block:: systemverilog

   cdc_handshake #(
     .DATA_WIDTH (32),
     .STAGES     (2)
   ) u_cfg_cross (
     .src_clk   (clk_cpu),
     .src_rst_n (rst_n_cpu),
     .src_valid (cfg_valid),
     .src_ready (cfg_ready),
     .src_data  (cfg_word),
     .dst_clk   (clk_dsp),
     .dst_rst_n (rst_n_dsp),
     .dst_valid (dsp_cfg_valid),
     .dst_ready (dsp_cfg_ready),
     .dst_data  (dsp_cfg_word)
   );

Crossing a wide measurement
---------------------------

Bundling related fields into one transfer is the point: they arrive together or
not at all, which a bank of synchronisers could never guarantee.

.. code-block:: systemverilog

   localparam int unsigned SAMPLE_W = 16 + 16 + 8;   // I, Q, status

   cdc_handshake #(
     .DATA_WIDTH (SAMPLE_W),
     .STAGES     (3)
   ) u_sample_cross (
     .src_clk   (clk_adc),
     .src_rst_n (rst_n_adc),
     .src_valid (sample_valid),
     .src_ready (sample_ready),
     .src_data  ({sample_i, sample_q, sample_status}),
     .dst_clk   (clk_core),
     .dst_rst_n (rst_n_core),
     .dst_valid (core_sample_valid),
     .dst_ready (core_sample_ready),
     .dst_data  (core_sample_word)
   );

Integration notes
-----------------

* Throughput is roughly one word per ``2 * STAGES`` cycles in each domain. If
  the source can produce faster than that, ``src_ready`` will throttle it
  correctly, but ``fifo_async`` is the right block for that traffic.
* Resetting one domain alone is safe. The transfer in flight at that moment is
  lost, and both sides return to idle once the other domain's control signal
  has settled.
* Apply ``scripts/cdc_handshake.sdc``. It includes the constraint that is
  easiest to forget: the payload register to destination capture path crosses
  domains without a synchroniser *by design*, and must be declared as a false
  path with a bounded delay rather than left to be timed.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_cdc_handshake.py``
     - Reset state; a single word; ``src_ready`` staying closed for the whole
       round trip; destination back-pressure holding the payload unchanged for
       ten cycles; randomised corner-biased streams with randomised
       back-pressure at three clock ratios (23/7, 7/23 and 10/10.7 ns); order
       and count preservation over 300 words; and recovery after both domains
       are reset mid-stream.
   * - ``tb/tb_cdc_handshake.sv``
     - Portable self-checking smoke test at 10 ns / 23 ns, streaming 400 words
       with and without destination back-pressure.

.. code-block:: bash

   ctest --test-dir build -R 'cdc_handshake'
