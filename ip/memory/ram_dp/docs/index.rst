.. _ip-ram_dp:

======
ram_dp
======

True dual-port synchronous RAM. Both ports read and write, each in its own
clock domain.

Functional description
======================

The block is written as an inferable array with no vendor primitive, so it
maps onto an FPGA block RAM in true dual-port mode or an ASIC dual-port macro
according to the target tool's heuristics.

Collision behaviour
-------------------

.. warning::

   The block does **not** arbitrate between the ports. Physical dual-port
   memories do not either, and pretending otherwise in RTL would produce a
   design that simulates differently from the hardware it becomes.

.. list-table::
   :header-rows: 1
   :widths: 42 58

   * - Access
     - Result
   * - Read / read, any addresses
     - Always safe.
   * - Read / write, different addresses
     - Always safe.
   * - Read / write, same address
     - Old data if the two clock edges are far enough apart; **undefined** if
       they coincide.
   * - Write / write, same address
     - **Undefined** contents afterwards.

"Coincide" means within the memory's own write-through window, which is a
physical property of the macro and is not modelled here. Treat any
same-address access from both ports in the same cycle as undefined.

Satisfying the rules
--------------------

* **Partition the address space** — one port owns the even addresses, or each
  port owns half the array. This is what the block's own testbenches do.
* **Arbitrate outside the block**, so only one port is enabled at a time.
* **Use** ``fifo_async`` for a producer and consumer sharing data across clock
  domains: it is this memory plus the pointer logic that makes the sharing
  provably safe.

If none of those apply, the design is relying on undefined behaviour.

If only one side ever writes, ``ram_sdp`` is the right block: it is smaller on
every target, has a single driving process, and its only collision rule is
read-first.

Lint exception
--------------

This is the only IP in the portfolio that declares a lint exception. Its
``CMakeLists.txt`` carries ``LINT_ARGS -Wno-MULTIDRIVEN``, because the array is
written from two clocked processes by necessity. The exception lives in the
build file rather than as an in-source pragma so that it stays visible and
auditable.

Block diagram
=============

.. code-block:: text

     port A (clk_a)                          port B (clk_b)
                                   |
   en_a  --->+---------------+     |     +---------------+<--- en_b
   we_a  --->| write + read  |     |     | write + read  |<--- we_b
   be_a  --->| process       |     |     | process       |<--- be_b
   addr_a--->|               |     |     |               |<--- addr_b
   wdata_a-->|               |     |     |               |<--- wdata_b
             +-------+-------+     |     +-------+-------+
                     |             |             |
                     v             |             v
              +---------------------------------------+
              |   mem[DEPTH][DATA_WIDTH]              |
              |   TWO driving processes - no          |
              |   arbitration, see collision rules    |
              +---------------------------------------+
                     |                           |
                     v                           v
                  rdata_a                     rdata_b

Timing diagram
==============

Concurrent access to different addresses, which is always safe:

.. code-block:: text

               .    .    .    .    .    .    .
   clk_a    __/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__
               .    .    .    .    .    .    .
   en_a     ____/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\______
   we_a     ____/‾‾‾‾‾\________________________
   addr_a   --< 04 >< 06 >< 06 >----------------
   rdata_a  --------< ?  >< M6 >< M6 >----------
               .    .    .    .    .    .    .
   clk_b    ___/‾‾‾‾‾‾‾\______/‾‾‾‾‾‾‾\______/‾‾
               .    .    .    .    .    .    .
   en_b     ______/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_____
   we_b     ______/‾‾‾‾‾‾‾‾‾‾‾\_________________
   addr_b   ------< 05       >< 07       >------
   rdata_b  ----------------< M5        >< M7 >-

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
     - Word width. A multiple of 8 when byte enables are used.
   * - ``DEPTH``
     - ``int unsigned``
     - 1024
     - >= 2
     - Number of words. Need not be a power of two.
   * - ``BYTE_ENABLE``
     - ``int unsigned``
     - 1
     - 0 or 1
     - Per-byte write masking on both ports.
   * - ``OUTPUT_REG``
     - ``int unsigned``
     - 0
     - 0 or 1
     - Registered outputs on both ports.
   * - ``INIT_FILE``
     - ``string``
     - ``""``
     - —
     - ``$readmemh`` file, simulation only.

Interface description
=====================

Both ports are identical. For ``x`` in ``{a, b}``:

.. list-table::
   :header-rows: 1
   :widths: 16 8 22 54

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk_x``
     - in
     - 1
     - Port clock. No relationship to the other port's clock is assumed.
   * - ``en_x``
     - in
     - 1
     - Access enable.
   * - ``we_x``
     - in
     - 1
     - Write when high, read when low.
   * - ``be_x``
     - in
     - ``DATA_WIDTH/8``
     - Byte enables.
   * - ``addr_x``
     - in
     - ``$clog2(DEPTH)``
     - Word address.
   * - ``wdata_x``
     - in
     - ``DATA_WIDTH``
     - Write data.
   * - ``rdata_x``
     - out
     - ``DATA_WIDTH``
     - Read data, one cycle later, or two with ``OUTPUT_REG``.

Usage examples
==============

A shared mailbox with a partitioned address space
-------------------------------------------------

Each side owns half the array, so the ports never touch the same word:

.. code-block:: systemverilog

   // Port A writes the lower half, reads the upper.
   // Port B writes the upper half, reads the lower.
   ram_dp #(
     .DATA_WIDTH (32),
     .DEPTH      (512)
   ) u_mailbox (
     .clk_a (clk_cpu),  .en_a (cpu_en),  .we_a (cpu_we),
     .be_a  (cpu_be),   .addr_a (cpu_addr), .wdata_a (cpu_wdata),
     .rdata_a (cpu_rdata),
     .clk_b (clk_dsp),  .en_b (dsp_en),  .we_b (dsp_we),
     .be_b  (dsp_be),   .addr_b (dsp_addr), .wdata_b (dsp_wdata),
     .rdata_b (dsp_rdata)
   );

Integration notes
-----------------

* No timing constraint makes a same-address collision safe. The hazard is
  inside the macro and is a physical property of it, not a path a tool can
  analyse. The address partitioning has to be guaranteed by the design.
* A true dual-port macro is substantially larger than a 1R1W one on most
  targets. Reach for ``ram_sdp`` first and only use this block when both sides
  genuinely write.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_ram_dp.py``
     - Each port reading its own writes; data written on one port read from
       the other; byte-enable masking on both; concurrent access to different
       addresses; 240 randomised operations per ratio over a partitioned
       address space at three clock ratios; a full sweep written from A and
       read from B; and the address boundaries from both ports.
   * - ``tb/tb_ram_dp.sv``
     - Portable smoke test at a 10 ns / 17 ns clock ratio. Its concurrent
       phase is driven by two independent processes rather than a ``fork``:
       Verilator 5.020 miscompiles a fork whose branches call automatic tasks
       containing timing controls, and the model aborts at run time.

.. code-block:: bash

   ctest --test-dir build -R 'ram_dp'
