.. _ip-fifo_sync:

=========
fifo_sync
=========

Synchronous FIFO with ready/valid interfaces, first-word-fall-through and
programmable threshold flags.

Functional description
======================

Storage is a ``ram_sdp`` instance, so the FIFO costs one block RAM rather than
``DEPTH * DATA_WIDTH`` flip-flops. That choice brings one problem with it: a
synchronous RAM has a cycle of read latency, while first-word-fall-through
means the head word must be visible on the output *before* anyone asks for it.

The show-ahead output stage
---------------------------

The two are reconciled by an output stage of two registers that runs ahead of
the consumer, prefetching from the RAM whenever it has room.

The stage is two entries deep rather than one for a specific reason. A read
issued to the RAM this cycle delivers its word next cycle, and that word must
have somewhere to go on arrival regardless of what the consumer does in
between. One entry would mean either stalling the prefetch whenever the output
is occupied — halving the throughput — or dropping a word.

The write bypass
----------------

When the RAM is empty and no read is in flight, an incoming word is written
straight into the output stage instead of going through the RAM. That takes
the empty-FIFO latency from three cycles to one, which matters for a FIFO used
as a pipeline stage rather than as a buffer.

The bypass is suppressed whenever anything is already in the RAM or in flight,
so an earlier word can never be overtaken.

Capacity
--------

The FIFO holds ``DEPTH`` words in total. Words live either in the RAM or in the
output stage, and ``level`` counts both, so the number reported is the number a
consumer can actually still read.

Block diagram
=============

.. code-block:: text

                    +--------------------------------------------------+
   s_valid -------->|  occupancy: ram_count, inflight, out_count        |
   s_ready <--------|  s_ready = level < DEPTH                          |
   s_data  ---+---->|                                                   |
              |     |     bypass?  (RAM empty and nothing in flight)    |
              |     +-------+------------------------------+------------+
              |             | no                           | yes
              v             v                              |
        +----------------------------+                     |
        |  ram_sdp, DEPTH entries    |                     |
        |  wr_ptr / rd_ptr           |                     |
        +-------------+--------------+                     |
                      | prefetch when the output stage      |
                      | will have room on arrival           |
                      v                                     v
              +---------------------------------------------------+
              |  output stage: 2 registers, show-ahead            |---> m_valid
              |  out_data_q[0] is the head                        |---> m_data
              +---------------------------------------------------+<--- m_ready

Timing diagram
==============

A write into an empty FIFO taking the bypass, then a stalled read:

.. code-block:: text

               .    .    .    .    .    .    .    .
   clk      __/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__
               .    .    .    .    .    .    .    .
   s_valid  ____/‾‾‾‾‾\_________________________________
   s_ready  ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
   s_data   --< D0 >-------------------------------------
               .    .    .    .    .    .    .    .
   m_valid  _________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_____________
   m_data   ---------< D0                  >-------------
   m_ready  ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_________/‾‾‾‾‾‾‾‾‾‾‾‾‾
               .    .    .    .    .    .    .    .
   level    < 0 >< 1                       >< 0 >--------
                    ^                        ^
                    |                        +-- consumed here
                    +-- one cycle after the write: the bypass

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 26 16 14 12 32

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 32
     - >= 1
     - Payload width.
   * - ``DEPTH``
     - ``int unsigned``
     - 16
     - >= 2
     - Total capacity in words. Need not be a power of two.
   * - ``ALMOST_FULL_LEVEL``
     - ``int unsigned``
     - ``DEPTH-1``
     - <= ``DEPTH``
     - ``almost_full`` asserts at this level or above.
   * - ``ALMOST_EMPTY_LEVEL``
     - ``int unsigned``
     - 1
     - < ``DEPTH``
     - ``almost_empty`` asserts at this level or below.

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
   * - ``s_valid`` / ``s_ready``
     - —
     - 1
     - Write handshake. A transfer occurs when both are high.
   * - ``s_data``
     - in
     - ``DATA_WIDTH``
     - Write payload. Must be stable while stalled.
   * - ``m_valid`` / ``m_ready``
     - —
     - 1
     - Read handshake.
   * - ``m_data``
     - out
     - ``DATA_WIDTH``
     - Head word, presented before it is requested.
   * - ``level``
     - out
     - ``$clog2(DEPTH+1)``
     - Words currently held, RAM and output stage together.
   * - ``full`` / ``empty``
     - out
     - 1
     - Occupancy flags.
   * - ``almost_full`` / ``almost_empty``
     - out
     - 1
     - Programmable threshold flags.

Usage examples
==============

A rate-matching buffer
----------------------

.. code-block:: systemverilog

   fifo_sync #(
     .DATA_WIDTH        (64),
     .DEPTH             (32),
     .ALMOST_FULL_LEVEL (24)
   ) u_fifo (
     .clk (clk), .rst_n (rst_n),
     .s_valid (up_valid), .s_ready (up_ready), .s_data (up_data),
     .m_valid (dn_valid), .m_ready (dn_ready), .m_data (dn_data),
     .level (), .full (), .empty (),
     .almost_full (throttle_upstream), .almost_empty ()
   );

``almost_full`` is set eight words below capacity so an upstream block with a
few cycles of pipeline latency can stop in time.

As a pipeline stage
-------------------

With the write bypass the empty-FIFO latency is one cycle, so a shallow FIFO is
a reasonable register slice that also absorbs short bursts:

.. code-block:: systemverilog

   fifo_sync #(.DATA_WIDTH(32), .DEPTH(4)) u_slice (
     .clk (clk), .rst_n (rst_n),
     .s_valid (a_valid), .s_ready (a_ready), .s_data (a_data),
     .m_valid (b_valid), .m_ready (b_ready), .m_data (b_data),
     .level (), .full (), .empty (), .almost_full (), .almost_empty ()
   );

Integration notes
-----------------

* ``s_ready`` and ``m_valid`` are combinational from the occupancy counters.
  Both are short paths, but they connect a producer to a consumer through the
  FIFO; if that becomes the critical path, add a register slice outside rather
  than changing this block, since breaking the ready path internally costs
  either throughput or capacity.
* For crossing clock domains use ``fifo_async``. This block is single-clock
  only.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_fifo_sync.py``
     - Reset state; first-word-fall-through with the latency measured and
       asserted to be within two cycles, which is what proves the bypass is
       working; filling to exactly ``DEPTH`` and the next write refused;
       draining in order; the almost flags checked at every level from 0 to
       ``DEPTH``; 500 words of corner-biased randomised traffic with
       back-pressure on both sides; 1000 words at full rate; the FIFO parked
       full and then streamed through; and a mid-stream reset. Run at depths
       16, 5 and 2.
   * - ``tb/tb_fifo_sync.sv``
     - Portable self-checking smoke test with a continuous level-bound check.
   * - ``formal/fifo_sync_formal.sv``
     - k-induction proof at ``DEPTH=5``: every word leaves once and in
       order, level and all four flags are exact, nothing is accepted while
       full, and a waiting word holds.

.. code-block:: bash

   ctest --test-dir build -R 'fifo_sync'
