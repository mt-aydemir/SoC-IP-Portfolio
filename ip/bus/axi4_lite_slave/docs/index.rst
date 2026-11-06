.. _ip-axi4_lite_slave:

===============
axi4_lite_slave
===============

AMBA AXI4-Lite subordinate that bridges reads and writes onto a simple register
request port.

Functional description
======================

Channels
--------

AXI4-Lite has five channels, each with its own valid/ready handshake, and the
protocol orders nothing between them except that a write's B response follows
its address and data. The block therefore treats each channel on its own:

* **AW, W, AR** each have a one-entry holding register. The channel's ready
  is high whenever the register is empty, so an address or data beat is
  accepted the cycle it is offered unless one is already waiting. A write's
  address and data may arrive in either order or in the same cycle.
* **B, R** are registered. A response is posted on the edge its register
  request is taken and held until the manager accepts it.

Request selection
-----------------

A write is ready to issue once both AW and W are held and no B response is
outstanding; a read once AR is held and no R response is outstanding. When
both are ready, the write goes first.

A request, once offered on the register port, must not change until it is
taken. The choice between read and write is therefore locked whenever the
request waits on ``reg_ready``; without the lock, a write becoming ready while
a read waits would replace the read mid-request.

No fairness state is needed. A direction that has just been served cannot be
ready again in the next cycle - its response register is full and its holding
registers are empty - so when both directions are saturated they strictly
alternate. The test suite checks exactly that, with and without wait states.

Responses
---------

``reg_error`` sampled on the accepting edge becomes ``SLVERR`` (``2'b10``);
otherwise the response is ``OKAY``. ``RDATA`` is ``reg_rdata`` from the same
edge.

Ordering
--------

As AXI specifies, a read may overtake an earlier write to the same address:
the channels are independent. A manager that needs read-after-write order
waits for the write's B response before issuing the read.

Block diagram
=============

.. code-block:: text

   AW --> [aw hold] --+
                      +-- write ready (and no B) --+
   W  --> [w hold]  --+                            +--> select/lock --> reg_*
                                                   |
   AR --> [ar hold] ----- read ready (and no R) ---+
                                                         reg_rdata/reg_error
                                                                 |
                              B <-- [bvalid, bresp] <------------+
                              R <-- [rvalid, rdata, rresp] <-----+

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
   * - ``ADDR_WIDTH``
     - ``int unsigned``
     - 12
     - 2 to 64
     - ``AWADDR``, ``ARADDR`` and ``reg_addr`` width.
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 32
     - 32, 64
     - Data width, the two AXI4-Lite allows.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 30 8 18 44

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``, ``rst_n``
     - in
     - 1
     - ``ACLK`` and ``ARESETn``.
   * - ``s_axi_awvalid`` / ``s_axi_awready``
     - in / out
     - 1
     - Write address handshake.
   * - ``s_axi_awaddr``, ``s_axi_awprot``
     - in
     - ``ADDR_WIDTH``, 3
     - Write address and protection.
   * - ``s_axi_wvalid`` / ``s_axi_wready``
     - in / out
     - 1
     - Write data handshake.
   * - ``s_axi_wdata``, ``s_axi_wstrb``
     - in
     - ``DATA_WIDTH``, ``DATA_WIDTH/8``
     - Write data and byte strobes.
   * - ``s_axi_bvalid`` / ``s_axi_bready``
     - out / in
     - 1
     - Write response handshake.
   * - ``s_axi_bresp``
     - out
     - 2
     - ``OKAY`` or ``SLVERR``.
   * - ``s_axi_arvalid`` / ``s_axi_arready``
     - in / out
     - 1
     - Read address handshake.
   * - ``s_axi_araddr``, ``s_axi_arprot``
     - in
     - ``ADDR_WIDTH``, 3
     - Read address and protection.
   * - ``s_axi_rvalid`` / ``s_axi_rready``
     - out / in
     - 1
     - Read data handshake.
   * - ``s_axi_rdata``, ``s_axi_rresp``
     - out
     - ``DATA_WIDTH``, 2
     - Read data and response.
   * - ``reg_valid`` / ``reg_ready``
     - out / in
     - 1
     - Register request handshake.
   * - ``reg_write``, ``reg_addr``, ``reg_wdata``, ``reg_strb``, ``reg_prot``
     - out
     - 1, ``ADDR_WIDTH``, ``DATA_WIDTH``, ``DATA_WIDTH/8``, 3
     - The request; data and strobes are zero on a read.
   * - ``reg_rdata``, ``reg_error``
     - in
     - ``DATA_WIDTH``, 1
     - The response, sampled on the accepting edge.

Integration notes
-----------------

* The register port is ``apb_slave``'s; see its integration notes for
  connecting a block with a combinational read.
* One write and one read in flight make the block a register slave, not a
  memory slave: each direction completes at most one transfer every two
  cycles. For bulk data use AXI4-Stream.
* Read side effects belong on ``reg_valid && reg_ready && !reg_write``.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_axi4_lite_slave.py``
     - A five-channel manager and a register block written from the
       specifications. Covers the reset state, write data before, with and
       after its address, wait states, SLVERR, strobes, a stalled B channel
       that does not stall reads and the reverse, strict alternation under
       saturation, a reset in flight, and 1500 random transfers with random
       delays on every channel. Every cycle also checks that no AXI output
       follows the register response combinationally. Run at the registered
       parameters and, by hand, at 64-bit data and 4- and 32-bit addresses.
   * - ``tb/tb_axi4_lite_slave.sv``
     - Independent AW, W and AR driver processes with random delays,
       random B and R back-pressure, and a register block with wait states
       and an error word; 3000 operations.
   * - ``formal/axi4_lite_slave_formal.sv``
     - k-induction proof against an AXI4-Lite manager: pairing of
       AW, W and AR with their requests, one response each, SLVERR and read
       data, hold, and read/write alternation.
   * - ``uvm/axi4_lite_slave_uvm_pkg.sv``
     - UVM 2020 environment: an AXI4-Lite manager agent with independent
       write and read workers, a reactive register block, a scoreboard in
       register-request order with a reference memory, and a covergroup.
       600 random transactions at full coverage and 400 at saturation.

.. code-block:: bash

   ctest --test-dir build -R 'axi4_lite_slave'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration. The
register response is reported as its own path group by
``scripts/axi4_lite_slave.sdc``.
