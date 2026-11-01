.. _ip-ram_sp:

======
ram_sp
======

Single-port synchronous RAM with byte enables and an optional output register.

Functional description
======================

The block is written as an inferable array with no vendor primitive and no
``ram_style`` attribute, so the same source maps onto FPGA block RAM, FPGA
distributed RAM or an ASIC macro according to the target tool's own
heuristics. Guiding that choice belongs in the project's constraints, not in
this file.

The structure is the one every synthesiser recognises as a synchronous RAM: a
single clocked process containing the write, and a registered read from the
same array. Anything more elaborate — a read in a separate process, an
asynchronous read, a reset on the array — prevents inference and silently
produces a wall of flip-flops instead.

No reset
--------

The array is not reset, and neither is the output register. A reset on the
array would force every bit into fabric flip-flops: a 1024x32 array becomes
32768 registers instead of one block RAM. Resetting only the output register
would be a false promise, since the value it holds is meaningless until a read
has been issued anyway.

Contents are undefined until written and ``rdata`` is undefined until a read
completes, exactly as for any real memory. The block has no ``rst_n`` port at
all rather than an unused one.

Read-during-write
-----------------

Reading and writing the same address in the same cycle returns the **old**
contents — "read first". This is the behaviour every target can implement.
Write-first is not universally available and is deliberately not offered as a
parameter: an option that silently changes meaning between targets is worse
than no option. A caller needing the new data should bypass around the memory,
which is what ``fifo_sync`` does for its first-word-fall-through path.

Block diagram
=============

.. code-block:: text

              +-------------------------------------------------+
    en  ----->|                                                  |
    we  ----->|  write path: per-byte masking from be            |
    be  ----->|        +-------------------------------+         |
    addr ---->|        |  mem[DEPTH][DATA_WIDTH]       |         |
    wdata --->|------->|                               |         |
              |        +---------------+---------------+         |
              |                        | registered read         |
              |                        v                         |
              |                 +-------------+                  |
              |                 | read_data   |                  |
              |                 +------+------+                  |
              |                        |                         |
              |          OUTPUT_REG ?  |  : ---------------------|--> rdata
              |                        v                         |
              |                 +-------------+                  |
              |                 | rdata reg   |------------------|--> rdata
              |                 +-------------+                  |
              +-------------------------------------------------+

Timing diagram
==============

``OUTPUT_REG = 0``, one cycle of read latency:

.. code-block:: text

               .    .    .    .    .    .    .
   clk      __/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__
               .    .    .    .    .    .    .
   en       ____/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\______
               .    .    .    .    .    .    .
   we       ____/‾‾‾‾‾\__________________________
               .    .    .    .    .    .    .
   addr     --< A0 >< A1 >< A0 >< A2 >------------
   wdata    --< D0 >------------------------------
               .    .    .    .    .    .    .
   rdata    --------< ?  >< M1 >< D0 >< M2 >------
                              ^
                              +-- the word written at A0 two cycles earlier

``OUTPUT_REG = 1`` shifts every ``rdata`` value one cycle later. The extra
register costs a cycle and buys timing closure; on an FPGA it maps into the
block RAM's own output register and costs no fabric at all, which usually makes
it free in area and a large win in Fmax.

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
     - >= 8
     - Word width. Must be a multiple of 8 when byte enables are used.
   * - ``DEPTH``
     - ``int unsigned``
     - 1024
     - >= 2
     - Number of words. Need not be a power of two.
   * - ``BYTE_ENABLE``
     - ``int unsigned``
     - 1
     - 0 or 1
     - Per-byte write masking.
   * - ``OUTPUT_REG``
     - ``int unsigned``
     - 0
     - 0 or 1
     - Registered output stage, adding one cycle of read latency.
   * - ``INIT_FILE``
     - ``string``
     - ``""``
     - —
     - ``$readmemh`` file, loaded in simulation only. Synthesis ignores it.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 14 8 22 56

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``
     - in
     - 1
     - Clock.
   * - ``en``
     - in
     - 1
     - Access enable. With it low nothing changes and ``rdata`` is held.
   * - ``we``
     - in
     - 1
     - Write when high, read when low. A write also issues the read.
   * - ``be``
     - in
     - ``DATA_WIDTH/8``
     - Byte enables. Ignored when ``BYTE_ENABLE`` is 0.
   * - ``addr``
     - in
     - ``$clog2(DEPTH)``
     - Word address.
   * - ``wdata``
     - in
     - ``DATA_WIDTH``
     - Write data.
   * - ``rdata``
     - out
     - ``DATA_WIDTH``
     - Read data, valid one cycle later, or two with ``OUTPUT_REG``.

Usage examples
==============

Instruction memory with an initialisation image
-----------------------------------------------

.. code-block:: systemverilog

   ram_sp #(
     .DATA_WIDTH  (32),
     .DEPTH       (4096),
     .BYTE_ENABLE (0),
     .OUTPUT_REG  (0),
     .INIT_FILE   ("firmware.hex")
   ) u_imem (
     .clk   (clk),
     .en    (fetch_en),
     .we    (1'b0),
     .be    ('1),
     .addr  (pc[13:2]),
     .wdata ('0),
     .rdata (instruction)
   );

Data memory with byte writes and a pipelined output
---------------------------------------------------

.. code-block:: systemverilog

   ram_sp #(
     .DATA_WIDTH  (32),
     .DEPTH       (8192),
     .BYTE_ENABLE (1),
     .OUTPUT_REG  (1)
   ) u_dmem (
     .clk   (clk),
     .en    (mem_en),
     .we    (mem_we),
     .be    (mem_be),
     .addr  (mem_addr),
     .wdata (mem_wdata),
     .rdata (mem_rdata)
   );

Integration notes
-----------------

* ``en`` must stay asserted for the output register to advance. That is
  deliberate: it means ``rdata`` holds its value while a consumer stalls,
  which is what a block RAM's output register does.
* Behind a bus, use ``bram_ctrl`` rather than wiring this block directly. A
  bus needs flow control and a response per request, and this block provides
  neither.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_ram_sp.py``
     - Write and read back at four addresses including both boundaries;
       byte-enable masking lane by lane; read-during-write returning old data
       and the write still landing; the enable holding the output; 600
       randomised operations against a dictionary model; and a sweep of the
       first 256 locations. The read latency is derived from ``OUTPUT_REG``
       rather than assumed, so the suite is meaningful at both settings, and
       it is run at three parameter configurations.
   * - ``tb/tb_ram_sp.sv``
     - Portable self-checking smoke test covering the same behaviour.

.. code-block:: bash

   ctest --test-dir build -R 'ram_sp'
