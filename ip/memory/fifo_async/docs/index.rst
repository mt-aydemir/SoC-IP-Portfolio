.. _ip-fifo_async:

==========
fifo_async
==========

Asynchronous FIFO. Moves a data stream between two clock domains of arbitrary,
unrelated frequencies.

Functional description
======================

This is the block to use for continuous traffic across a clock domain
boundary. ``cdc_handshake`` pays a full round trip per word and is the right
choice for occasional transfers; this one sustains one word per cycle in each
domain.

How the pointers cross
----------------------

The only things that cross the boundary are the two pointers, and they cross
Gray coded.

A binary counter stepping from ``0111`` to ``1000`` changes every bit at once,
so a synchroniser sampling it mid-transition can produce any of the sixteen
values — including values the counter never held. Gray code changes exactly one
bit per increment, so a sample taken during a transition yields either the old
value or the new one. Never anything else.

That property is what makes the comparison safe rather than merely usually
correct. A stale pointer makes the FIFO look emptier than it is on the write
side, and fuller than it is on the read side — conservative in both directions,
which is the only acceptable direction to be wrong in.

The guard bit
-------------

The pointers are one bit wider than the address they carry. That extra bit
distinguishes full from empty: both conditions have equal address bits, and
they differ only in whether the pointers have wrapped a different number of
times.

Empty is an exact match of the whole Gray-coded pointer. Full is a match of the
low bits with the top two inverted, which is what a one-wrap difference looks
like in Gray code.

Why DEPTH must be a power of two
--------------------------------

Gray coding relies on the counter wrapping exactly at the top of its range. A
counter that wraps early produces two adjacent codes differing in more than one
bit, and the whole guarantee collapses — a synchroniser sampling that
transition can return a value neither side ever held. The constraint is checked
at elaboration with ``$fatal``.

Show-ahead output
-----------------

Storage is a ``ram_sdp``, so a read takes a cycle, and first-word-fall-through
requires the head word to be visible before it is asked for. The read side
therefore runs a two-entry prefetch stage ahead of the consumer, exactly as
``fifo_sync`` does. The stage holds up to two words beyond the ``DEPTH`` stored
in the RAM, so total capacity is ``DEPTH + 2``; ``wr_full`` refers to the RAM,
which is what the writer needs to know.

Block diagram
=============

.. code-block:: text

     write domain (wr_clk)          |        read domain (rd_clk)
                                    |
   s_valid -->+----------------+    |    +------------------+--> m_valid
   s_ready <--| wr_ptr (bin)   |    |    | rd_ptr (bin)     |<-- m_ready
   s_data  -->| wr_ptr (gray)  |    |    | rd_ptr (gray)    |
              +-------+--------+    |    +--------+---------+
                      |             |             |
                      |  +----------|----------+  |
                      +->| cdc_sync_2ff, gray  |--+---> empty compare
                         +----------|----------+  |
                                    |             |
                         +----------|----------+  |
        full compare <---| cdc_sync_2ff, gray  |<-+
                         +----------|----------+
                                    |
   s_data ==================>[ ram_sdp, DEPTH ]==========> show-ahead
                                    |                       2 registers
                                    |                            |
                                    |                            v
                                    |                         m_data

Timing diagram
==============

A word crossing from a fast writer to a slow reader, ``SYNC_STAGES = 2``:

.. code-block:: text

               .   .   .   .   .   .   .   .   .   .
   wr_clk   __/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_
               .   .   .   .   .   .   .   .   .   .
   s_valid  ___/‾‾‾\_________________________________
   s_ready  ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
   s_data   --< D0 >---------------------------------
               .   .   .   .   .   .   .   .   .   .
   wr_gray  ___/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾   one bit changes
               .   .   .   .   .   .   .   .   .   .
   rd_clk   ____/‾‾‾‾‾‾‾\_______/‾‾‾‾‾‾‾\_______/‾‾‾‾
               .   .   .   .   .   .   .   .   .   .
   wr_gray_sync ______________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾   after SYNC_STAGES
               .   .   .   .   .   .   .   .   .   .
   m_valid  ______________________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
   m_data   ----------------------< D0             >--

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 26 16 14 16 28

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
     - power of two, >= 4
     - RAM depth in words. Total capacity is ``DEPTH + 2``.
   * - ``SYNC_STAGES``
     - ``int unsigned``
     - 2
     - >= 2
     - Synchroniser depth for both pointer crossings. Sets the latency.
   * - ``ALMOST_FULL_LEVEL``
     - ``int unsigned``
     - ``DEPTH-2``
     - <= ``DEPTH``
     - Write-side threshold.
   * - ``ALMOST_EMPTY_LEVEL``
     - ``int unsigned``
     - 1
     - < ``DEPTH``
     - Read-side threshold.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 26 8 10 56

   * - Signal
     - Dir
     - Domain
     - Description
   * - ``wr_clk`` / ``wr_rst_n``
     - in
     - write
     - Write clock and active-low reset.
   * - ``s_valid`` / ``s_ready``
     - —
     - write
     - Write handshake.
   * - ``s_data``
     - in
     - write
     - Write payload. Must be stable while stalled.
   * - ``wr_level``
     - out
     - write
     - Words in the RAM. Conservative: never reports fewer than there are.
   * - ``wr_full`` / ``wr_almost_full``
     - out
     - write
     - Write-side status.
   * - ``rd_clk`` / ``rd_rst_n``
     - in
     - read
     - Read clock and active-low reset.
   * - ``m_valid`` / ``m_ready``
     - —
     - read
     - Read handshake.
   * - ``m_data``
     - out
     - read
     - Head word, presented before it is requested.
   * - ``rd_level``
     - out
     - read
     - Words in the RAM. Conservative in the other direction.
   * - ``rd_empty`` / ``rd_almost_empty``
     - out
     - read
     - Read-side status.

Usage examples
==============

Crossing an ADC stream into the core domain
-------------------------------------------

.. code-block:: systemverilog

   fifo_async #(
     .DATA_WIDTH  (16),
     .DEPTH       (64),
     .SYNC_STAGES (2)
   ) u_adc_fifo (
     .wr_clk (clk_adc), .wr_rst_n (rst_n_adc),
     .s_valid (adc_valid), .s_ready (adc_ready), .s_data (adc_sample),
     .wr_level (), .wr_full (adc_overflow_risk), .wr_almost_full (),
     .rd_clk (clk_core), .rd_rst_n (rst_n_core),
     .m_valid (core_valid), .m_ready (core_ready), .m_data (core_sample),
     .rd_level (), .rd_empty (), .rd_almost_empty ()
   );

Sizing the depth
----------------

The depth must cover the worst-case burst the reader cannot keep up with, plus
the synchroniser latency in both directions. A reader that stalls for ``N``
cycles while the writer runs at full rate needs at least ``N + 2*SYNC_STAGES +
2`` entries; round up to the next power of two.

Integration notes
-----------------

* Each domain needs its own reset, released synchronously to its own clock.
  Use one ``cdc_reset_sync`` per domain.
* Resetting one domain alone is safe but loses whatever was in flight. Both
  sides return to a consistent state once the other domain's pointer has
  settled.
* ``scripts/fifo_async.sdc`` is load bearing, unlike most of the memory
  constraint fragments. Without it the pointer crossings are either left
  unanalysed by accident or analysed as if the clocks were related.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_fifo_async.py``
     - Reset state in both domains; a single word crossing; filling the RAM to
       capacity, which takes ``DEPTH + 2`` writes because the show-ahead stage
       pulls two words out regardless of ``m_ready``; draining in order;
       randomised corner-biased streams with back-pressure at three clock
       ratios; sustained full-rate traffic writer-bound and reader-bound; a run
       long enough for twenty full pointer wraps, which is the only way the
       guard bit is really exercised; and recovery after reset. Run at depths
       16 and 4.
   * - ``tb/tb_fifo_async.sv``
     - Portable smoke test at a 10 ns / 23 ns clock ratio, 600 words with
       randomised back-pressure and a continuous level-bound check.

.. code-block:: bash

   ctest --test-dir build -R 'fifo_async'
