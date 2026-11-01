.. _ip-ram_sdp:

=======
ram_sdp
=======

Simple dual-port synchronous RAM: one write port and one read port, each in its
own clock domain.

Functional description
======================

This is the most useful memory configuration in practice and the cheapest
dual-port structure a target can provide. Every FPGA block RAM supports it
natively, and on an ASIC it maps to a 1R1W macro substantially smaller than a
true dual-port one.

It is also the only dual-port arrangement with a **single driving process** for
the array. A true dual-port memory is written from two clocked processes and is
therefore multiply driven, with all the collision rules that implies. Here the
read port only reads, so there is nothing to collide and no lint exception is
needed.

``fifo_sync`` and ``fifo_async`` are both built on this block, which is why it
exists as an IP in its own right rather than as private storage inside each of
them.

Collision behaviour
-------------------

.. list-table::
   :header-rows: 1
   :widths: 45 55

   * - Access
     - Result
   * - Write and read, different addresses
     - Always safe.
   * - Write and read, same address
     - The read returns the **old** contents.

The second rule holds regardless of the clock relationship: the read is issued
from the array before the write in that cycle has landed. Callers needing the
new data must bypass around the memory, which is exactly what ``fifo_sync``
does for its first-word-fall-through path.

Block diagram
=============

.. code-block:: text

    write domain (wr_clk)          |          read domain (rd_clk)
                                   |
   wr_en  --->+-----------------+  |  +------------------+
   wr_be  --->| write process   |  |  | read process     |<--- rd_en
   wr_addr--->|                 |  |  |                  |<--- rd_addr
   wr_data--->|                 |  |  |                  |
              +--------+--------+  |  +---------+--------+
                       |           |            |
                       v           |            v
              +----------------------------------------+
              |    mem[DEPTH][DATA_WIDTH]              |
              |    one driving process only            |
              +----------------------------------------+
                                   |            |
                                   |            v
                                   |     +-------------+
                                   |     | read_data   |---> rd_data
                                   |     +-------------+
                                   |     (+ optional output register)

Timing diagram
==============

Concurrent traffic with unrelated clocks. The write at ``A1`` and the read of
``A0`` are simultaneous and independent:

.. code-block:: text

               .    .    .    .    .    .    .
   wr_clk   __/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__
               .    .    .    .    .    .    .
   wr_en    ____/‾‾‾‾‾‾‾‾‾‾‾\_____________________
   wr_addr  --< A0 >< A1 >------------------------
   wr_data  --< D0 >< D1 >------------------------
               .    .    .    .    .    .    .
   rd_clk   ___/‾‾‾‾‾‾‾\______/‾‾‾‾‾‾‾\______/‾‾‾‾
               .    .    .    .    .    .    .
   rd_en    ______/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_______
   rd_addr  ------< A0        >< A1       >-------
               .    .    .    .    .    .    .
   rd_data  ----------------< D0        >< D1 >---

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 20 18 12 14 36

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 32
     - >= 1
     - Word width. A multiple of 8 when byte enables are used.
   * - ``DEPTH``
     - ``int unsigned``
     - 1024
     - >= 2
     - Number of words. Need not be a power of two.
   * - ``BYTE_ENABLE``
     - ``int unsigned``
     - 0
     - 0 or 1
     - Per-byte write masking.
   * - ``OUTPUT_REG``
     - ``int unsigned``
     - 0
     - 0 or 1
     - Registered read output, adding one cycle of latency.
   * - ``INIT_FILE``
     - ``string``
     - ``""``
     - —
     - ``$readmemh`` file, simulation only.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 8 22 54

   * - Signal
     - Dir
     - Width
     - Description
   * - ``wr_clk``
     - in
     - 1
     - Write clock.
   * - ``wr_en``
     - in
     - 1
     - Write enable.
   * - ``wr_be``
     - in
     - ``DATA_WIDTH/8``
     - Byte enables. Ignored when ``BYTE_ENABLE`` is 0.
   * - ``wr_addr``
     - in
     - ``$clog2(DEPTH)``
     - Write address.
   * - ``wr_data``
     - in
     - ``DATA_WIDTH``
     - Write data.
   * - ``rd_clk``
     - in
     - 1
     - Read clock. May be the same net as ``wr_clk``.
   * - ``rd_en``
     - in
     - 1
     - Read enable. Holds ``rd_data`` when low.
   * - ``rd_addr``
     - in
     - ``$clog2(DEPTH)``
     - Read address.
   * - ``rd_data``
     - out
     - ``DATA_WIDTH``
     - Read data, one cycle later, or two with ``OUTPUT_REG``.

Usage examples
==============

A video line buffer across clock domains
----------------------------------------

.. code-block:: systemverilog

   ram_sdp #(
     .DATA_WIDTH (16),
     .DEPTH      (2048)
   ) u_line_buffer (
     .wr_clk  (clk_capture),
     .wr_en   (pixel_valid),
     .wr_be   ('1),
     .wr_addr (write_index),
     .wr_data (pixel),
     .rd_clk  (clk_process),
     .rd_en   (1'b1),
     .rd_addr (read_index),
     .rd_data (pixel_out)
   );

Single-clock use as FIFO storage
--------------------------------

.. code-block:: systemverilog

   ram_sdp #(
     .DATA_WIDTH (DATA_WIDTH),
     .DEPTH      (DEPTH)
   ) u_storage (
     .wr_clk  (clk), .wr_en (push), .wr_be ('1),
     .wr_addr (wr_ptr), .wr_data (push_data),
     .rd_clk  (clk), .rd_en (prefetch),
     .rd_addr (rd_ptr), .rd_data (pop_data)
   );

Integration notes
-----------------

* **This block provides no synchronisation between the domains.** Whatever
  tells the reader that a word is available must handle that, and getting it
  wrong is the classic clock-domain-crossing bug. ``fifo_async`` is exactly
  that logic, which is why it is built on this memory — use it rather than
  inventing a pointer scheme.
* Where both ports share one clock, tie ``rd_clk`` to ``wr_clk`` and skip the
  asynchronous clock-group declaration in the SDC: declaring a clock
  asynchronous to itself removes real timing checks.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_ram_sdp.py``
     - Write and read back; byte-enable masking; simultaneous access to
       different addresses; same-address collision returning old data with the
       write still landing; 200 randomised operations against a dictionary
       model at each of three clock ratios; a full sweep; and sustained
       concurrent traffic with the read port trailing the write port.
   * - ``tb/tb_ram_sdp.sv``
     - Portable smoke test at a 10 ns / 17 ns clock ratio.

.. code-block:: bash

   ctest --test-dir build -R 'ram_sdp'
