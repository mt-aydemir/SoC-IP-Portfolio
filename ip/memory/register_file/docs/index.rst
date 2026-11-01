.. _ip-register_file:

=============
register_file
=============

Multi-port register file with one write port and configurable asynchronous
read ports.

Functional description
======================

Reads are combinational: an instruction can present a register number and use
the value in the same cycle. That is what makes this a register file rather
than a RAM, and it is the property a processor datapath is built around.

It is also what makes it expensive. The storage infers as ``NUM_REGS *
DATA_WIDTH`` flip-flops, and each read port adds a multiplexer with
``NUM_REGS`` inputs. Area grows with the product of depth and port count, and
the read multiplexer is normally the block's critical path. For anything much
larger than a processor's architectural register set, or where a cycle of read
latency is acceptable, ``ram_sp`` or ``ram_sdp`` is the right block.

Read-during-write
-----------------

A read port addressing the register being written in the same cycle returns
the **new** data when ``BYPASS_WRITE`` is set, and the old data otherwise.
Processor register files normally want the bypass: without it the datapath
needs its own forwarding path from the write-back stage, which is the same
logic implemented one level up.

Register zero
-------------

With ``ZERO_REGISTER`` set, address 0 reads as zero and ignores writes, which
is the RISC-V and MIPS convention. The write is discarded inside the block
rather than being suppressed by the caller, so nothing upstream needs to
special-case it. Synthesis removes the storage for it.

Address range
-------------

When ``NUM_REGS`` is a power of two every address is valid. When it is not —
24 registers needs five address bits and leaves eight unmapped codes — writes
outside the array are discarded and flagged by an assertion.

The guard is generated rather than written as a plain comparison, because a
cast of ``NUM_REGS`` to the address width wraps to zero in the power-of-two
case. Written naively the comparison is constantly false, and *every* write is
silently discarded. That defect was present in the first implementation and
was caught by the block's own regression at the default configuration.

Block diagram
=============

.. code-block:: text

    write_en ----+
    write_addr --+---> write decode ---+
    write_data --+                     |
                                       v
                        +--------------------------------+
                        |  registers[NUM_REGS]           |
                        |  DATA_WIDTH flip-flops each    |
                        +--------------------------------+
                           |          |            |
              +------------+          |            +-------------+
              v                       v                          v
       +-------------+         +-------------+            +-------------+
       | mux, port 0 |         | mux, port 1 |    ...     | mux, port N |
       +------+------+         +------+------+            +------+------+
              |                       |                          |
        bypass|compare          bypass|compare            bypass |compare
              v                       v                          v
         read_data[0]            read_data[1]              read_data[N]

    Each port is an independent NUM_REGS-input multiplexer with its own
    bypass comparison, because two ports may address different registers.

Timing diagram
==============

A write followed by a read, and a coincident read-during-write:

.. code-block:: text

               .    .    .    .    .    .    .
   clk      __/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__
               .    .    .    .    .    .    .
   write_en ____/‾‾‾‾‾\_______/‾‾‾‾‾\____________
               .    .    .    .    .    .    .
   write_addr --< 5  >-------< 5   >-------------
   write_data --< AA >-------< BB  >-------------
               .    .    .    .    .    .    .
   read_addr  --------< 5  ><  5   >< 5  >-------
               .    .    .    .    .    .    .
   read_data  --------< AA ><  BB  >< BB >-------
                        ^        ^
                        |        +-- bypass: the write in progress
                        +----------- the registered value

The bypassed read returns ``BB`` in the same cycle the write is presented; the
register itself takes the value on the following edge.

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 22 18 10 12 38

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 32
     - >= 1
     - Width of each register.
   * - ``NUM_REGS``
     - ``int unsigned``
     - 32
     - >= 2
     - Number of registers. Need not be a power of two.
   * - ``NUM_READ_PORTS``
     - ``int unsigned``
     - 2
     - >= 1
     - Independent asynchronous read ports. Each costs a full multiplexer.
   * - ``ZERO_REGISTER``
     - ``int unsigned``
     - 1
     - 0 or 1
     - Hardwire register 0 to zero and ignore writes to it.
   * - ``BYPASS_WRITE``
     - ``int unsigned``
     - 1
     - 0 or 1
     - Read-during-write returns the new data.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 18 8 26 48

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``
     - in
     - 1
     - Clock. Writes take effect on the rising edge.
   * - ``rst_n``
     - in
     - 1
     - Active-low reset. Clears every register.
   * - ``write_en``
     - in
     - 1
     - Write enable.
   * - ``write_addr``
     - in
     - ``$clog2(NUM_REGS)``
     - Write address.
   * - ``write_data``
     - in
     - ``DATA_WIDTH``
     - Write data.
   * - ``read_addr``
     - in
     - ``NUM_READ_PORTS`` x ``$clog2(NUM_REGS)``
     - Packed read addresses, port 0 in the low bits.
   * - ``read_data``
     - out
     - ``NUM_READ_PORTS`` x ``DATA_WIDTH``
     - Packed read data, port 0 in the low bits.

The read ports are packed arrays so the port count stays a parameter rather
than a fixed set of signals.

Usage examples
==============

A RISC-V integer register file
------------------------------

.. code-block:: systemverilog

   register_file #(
     .DATA_WIDTH     (32),
     .NUM_REGS       (32),
     .NUM_READ_PORTS (2),
     .ZERO_REGISTER  (1),
     .BYPASS_WRITE   (1)
   ) u_regfile (
     .clk        (clk),
     .rst_n      (rst_n),
     .write_en   (wb_valid),
     .write_addr (wb_rd),
     .write_data (wb_data),
     .read_addr  ({id_rs2, id_rs1}),
     .read_data  ({rs2_value, rs1_value})
   );

A three-port scoreboard
-----------------------

.. code-block:: systemverilog

   register_file #(
     .DATA_WIDTH     (8),
     .NUM_REGS       (16),
     .NUM_READ_PORTS (3),
     .ZERO_REGISTER  (0)
   ) u_status (
     .clk        (clk),
     .rst_n      (rst_n),
     .write_en   (status_update),
     .write_addr (status_index),
     .write_data (status_value),
     .read_addr  ({probe_c, probe_b, probe_a}),
     .read_data  ({value_c, value_b, value_a})
   );

Integration notes
-----------------

* The read path is combinational from ``read_addr`` to ``read_data``. In a
  deeply pipelined design, present the address from a register and consume the
  data in the same stage; adding logic on both ends of that path is what turns
  it into the critical path.
* Do not try to force the storage into a block RAM. A block RAM cannot provide
  a combinational read; a tool that tries will either refuse or insert a cycle
  of latency the surrounding logic does not expect. If the density is needed,
  the fix is architectural — move to ``ram_sdp`` and add a pipeline stage.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_register_file.py``
     - Reset clearing every register; write then read; register zero ignoring
       writes; the read-during-write bypass, with the expected value derived
       from the parameters so the test is correct with the bypass disabled
       too; read-port independence via walking addresses; 1500 cycles of
       randomised traffic with every port checked on every cycle against a
       dictionary model; and a sweep writing a distinct value to every
       register, which is where a decoder that aliases two addresses shows up.
   * - ``tb/tb_register_file.sv``
     - Portable self-checking smoke test covering the same behaviour.

.. code-block:: bash

   ctest --test-dir build -R 'register_file'
