.. _ip-bram_ctrl:

=========
bram_ctrl
=========

Block RAM controller with a pipelined request/response interface.

Functional description
======================

A synchronous RAM is not directly usable behind a bus. It has fixed read
latency, it cannot be stalled once a read is issued, and it has no notion of
back-pressure: the data appears on the cycle it appears, whether or not anyone
is ready for it. A bus, by contrast, expects flow control in both directions
and expects a response for every request.

This block bridges the two. It accepts requests only when it can guarantee
somewhere to put the result, buffers responses so a stalled consumer never
loses data, and returns exactly one response per accepted request, in order.

Flow control
------------

The rule that makes it safe is that a request is accepted only if the response
buffer will have room for its result on arrival — counting the result already
in flight from the previous cycle. Once a read has been issued to the RAM it
cannot be recalled, so the room must be reserved *before* the request is
accepted, not after.

The buffer is two entries deep for the same reason ``fifo_sync``'s output stage
is: one entry would force the controller to idle whenever the consumer stalled
for a single cycle, halving throughput on a bus that back-pressures at all.

Write responses
---------------

Every accepted request produces a response, writes included. A write response
carries no data and exists so the interface is uniform: a bridge in front of
this block can map requests and responses one to one without tracking which
were writes. Set ``WRITE_RESPONSE`` to 0 for a fire-and-forget write port where
the bus does not need the completion.

Errors
------

An address outside the array is answered with ``rsp_err`` rather than being
allowed to wrap into a valid location, and it never reaches the memory.
Silently aliasing a bad address onto a good one turns a software bug into
corrupted data somewhere unrelated, which is far harder to find than an error
response.

Block diagram
=============

.. code-block:: text

              +------------------------------------------------------+
   req_valid->|  accept = expects_response ?                          |
   req_ready<-|           (buf_count + inflight < 2) : 1               |
   req_we  -->|                                                        |
   req_addr-->|--- address check ---> addr_valid ---+                  |
   req_be  -->|                                     |                  |
   req_wdata->|                                     |                  |
              |        +----------------------+     |                  |
              |------->|  ram_sp, DEPTH words |     |                  |
              |        +----------+-----------+     |                  |
              |                   | 1 cycle         | inflight_err     |
              |                   v                 v                  |
              |        +------------------------------------+          |
              |        | response buffer: 2 entries         |          |
              |        | {rdata, err}, in order             |--------->|--> rsp_valid
              |        +------------------------------------+          |--> rsp_rdata
              |                                             <----------|--- rsp_ready
              +------------------------------------------------------+

Timing diagram
==============

Two back-to-back requests, with the consumer stalling on the first response:

.. code-block:: text

               .    .    .    .    .    .    .    .
   clk      __/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__
               .    .    .    .    .    .    .    .
   req_valid ___/‾‾‾‾‾‾‾‾‾‾‾\___________________________
   req_ready ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
   req_addr  --< A0 >< A1 >--------------------------
               .    .    .    .    .    .    .    .
   rsp_valid ___________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\__________
   rsp_ready ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_________/‾‾‾‾‾‾‾‾‾‾‾‾‾
   rsp_rdata ------------< M0           >< M1 >-------
                             ^
                             +-- held while the consumer stalls; the second
                                 result waits in the buffer behind it

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 24 16 12 20 28

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 32
     - multiple of 8, >= 8
     - Word width.
   * - ``DEPTH``
     - ``int unsigned``
     - 1024
     - >= 2
     - Words in the array. Need not be a power of two.
   * - ``WRITE_RESPONSE``
     - ``int unsigned``
     - 1
     - 0 or 1
     - Answer writes as well as reads.
   * - ``INIT_FILE``
     - ``string``
     - ``""``
     - —
     - ``$readmemh`` file, simulation only.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 22 8 22 48

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk`` / ``rst_n``
     - in
     - 1
     - Clock and active-low reset.
   * - ``req_valid`` / ``req_ready``
     - —
     - 1
     - Request handshake.
   * - ``req_we``
     - in
     - 1
     - Write when high, read when low.
   * - ``req_addr``
     - in
     - ``$clog2(DEPTH)``
     - Word address.
   * - ``req_be``
     - in
     - ``DATA_WIDTH/8``
     - Byte enables for a write.
   * - ``req_wdata``
     - in
     - ``DATA_WIDTH``
     - Write data.
   * - ``rsp_valid`` / ``rsp_ready``
     - —
     - 1
     - Response handshake.
   * - ``rsp_rdata``
     - out
     - ``DATA_WIDTH``
     - Read data. Undefined for a write response.
   * - ``rsp_err``
     - out
     - 1
     - The request address was outside the array.

The request payload must be stable while ``req_valid`` is high and
``req_ready`` is low, and a response is held until ``rsp_ready``. Both halves
are checked by concurrent assertions.

Usage examples
==============

A memory endpoint behind a bus bridge
-------------------------------------

.. code-block:: systemverilog

   bram_ctrl #(
     .DATA_WIDTH     (32),
     .DEPTH          (8192),
     .WRITE_RESPONSE (1)
   ) u_bram (
     .clk (clk), .rst_n (rst_n),
     .req_valid (mem_req_valid), .req_ready (mem_req_ready),
     .req_we    (mem_req_we),    .req_addr  (mem_req_addr),
     .req_be    (mem_req_be),    .req_wdata (mem_req_wdata),
     .rsp_valid (mem_rsp_valid), .rsp_ready (mem_rsp_ready),
     .rsp_rdata (mem_rsp_rdata), .rsp_err   (mem_rsp_err)
   );

A fire-and-forget trace buffer
------------------------------

Writes need no completion, so the write path never occupies a response slot and
never throttles:

.. code-block:: systemverilog

   bram_ctrl #(
     .DATA_WIDTH     (64),
     .DEPTH          (4096),
     .WRITE_RESPONSE (0)
   ) u_trace (
     .clk (clk), .rst_n (rst_n),
     .req_valid (trace_valid), .req_ready (trace_ready),
     .req_we    (trace_we),    .req_addr  (trace_addr),
     .req_be    ('1),          .req_wdata (trace_data),
     .rsp_valid (dump_valid),  .rsp_ready (dump_ready),
     .rsp_rdata (dump_data),   .rsp_err   ()
   );

Integration notes
-----------------

* Responses are returned strictly in order. A bridge can therefore track
  outstanding requests with a simple counter or FIFO of side-band information;
  no tagging is needed.
* ``req_ready`` is combinational from the buffer occupancy. That is what lets
  the block accept a request in the same cycle the previous response is taken.
  If a bridge extends that path too far, add a register slice on the request
  channel rather than relaxing the block.
* ``rsp_err`` is a per-response flag, not a sticky status bit. Latch it in the
  bridge if the bus needs an error to persist.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_bram_ctrl.py``
     - Reset state; write then read with the response count checked;
       byte-enable masking; a response held unchanged for six cycles while the
       consumer stalls; an out-of-range address answered with ``rsp_err``; 300
       randomised operations with randomised response back-pressure, counting
       responses cumulatively because a backlog of write responses is normally
       outstanding; sustained one-request-per-cycle streaming; and a
       mid-stream reset after which data written beforehand still survives,
       since the array is not reset. Run at three parameter configurations.
   * - ``tb/tb_bram_ctrl.sv``
     - Portable self-checking smoke test with randomised response
       back-pressure and a one-response-per-request check.

.. code-block:: bash

   ctest --test-dir build -R 'bram_ctrl'
