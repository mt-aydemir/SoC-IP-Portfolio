.. _ip-apb_slave:

=========
apb_slave
=========

AMBA APB4 completer that bridges APB transfers onto a simple register request
port.

Functional description
======================

The register port
-----------------

The block turns every APB transfer into exactly one request on the register
port and returns that request's response as the transfer's ``PRDATA`` and
``PSLVERR``. A request transfers on the edge where ``reg_valid`` and
``reg_ready`` are both high; until then ``reg_valid`` and the payload hold.
``reg_rdata`` and ``reg_error`` are sampled on that same edge, so a register
block answers in the cycle it accepts.

The port is shared with ``axi4_lite_slave``. Register logic written against it
sits behind either bus without change, and a block that cannot answer
immediately simply holds ``reg_ready`` low: on APB the transfer gains wait
states.

Response modes
--------------

``REGISTERED`` selects how the response reaches the bus.

.. list-table::
   :header-rows: 1
   :widths: 14 30 56

   * - REGISTERED
     - Cycles per transfer
     - Behaviour
   * - 0
     - 2 (setup, access)
     - ``PREADY``, ``PRDATA`` and ``PSLVERR`` are ``reg_ready``,
       ``reg_rdata`` and ``reg_error``. The minimum APB transfer, with a
       combinational path from ``PADDR`` through the register read to
       ``PRDATA``.
   * - 1
     - 3 (setup, access, wait)
     - The response is captured and ``PREADY`` rises the cycle after the
       request is accepted. Every APB output is a flip-flop.

In registered mode a ``done`` flag marks the cycle in which the captured
response completes the transfer. It keeps the request from being issued a
second time in that cycle, when ``PSEL`` and ``PENABLE`` are still high.

Protocol notes
--------------

* APB holds every address and control signal from the setup phase to the
  end of the transfer, so the payload is forwarded rather than registered.
* ``PSTRB`` is passed through unchanged; APB4 requires it to be zero on a
  read, and an assertion checks that requester rule.
* ``PSLVERR`` is only meaningful while ``PREADY`` is high, and the block
  drives it low otherwise in registered mode.

Block diagram
=============

.. code-block:: text

   psel, penable --> access ----------------------> reg_valid
                                                    (REGISTERED=1: && !done)
   pwrite, paddr, pwdata, pstrb, pprot ------------> reg_write, reg_addr, ...

   reg_ready, reg_rdata, reg_error
        |
        +-- REGISTERED=0 -------------------------> pready, prdata, pslverr
        |
        +-- REGISTERED=1 --> [done, rdata, error] --> pready, prdata, pslverr

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
     - 2 to 32
     - ``PADDR`` and ``reg_addr`` width.
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 32
     - 8, 16, 32
     - Data width; APB's maximum is 32.
   * - ``REGISTERED``
     - ``int unsigned``
     - 1
     - 0, 1
     - Response mode, above.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 22 8 18 52

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``, ``rst_n``
     - in
     - 1
     - Clock (``PCLK``) and active-low asynchronous reset (``PRESETn``).
   * - ``psel``, ``penable``, ``pwrite``
     - in
     - 1
     - APB transfer control.
   * - ``paddr``
     - in
     - ``ADDR_WIDTH``
     - Byte address.
   * - ``pwdata``, ``pstrb``
     - in
     - ``DATA_WIDTH``, ``DATA_WIDTH/8``
     - Write data and byte strobes.
   * - ``pprot``
     - in
     - 3
     - Protection type.
   * - ``pready``, ``prdata``, ``pslverr``
     - out
     - 1, ``DATA_WIDTH``, 1
     - Transfer completion, read data, error.
   * - ``reg_valid`` / ``reg_ready``
     - out / in
     - 1
     - Register request handshake.
   * - ``reg_write``, ``reg_addr``, ``reg_wdata``, ``reg_strb``, ``reg_prot``
     - out
     - 1, ``ADDR_WIDTH``, ``DATA_WIDTH``, ``DATA_WIDTH/8``, 3
     - The request.
   * - ``reg_rdata``, ``reg_error``
     - in
     - ``DATA_WIDTH``, 1
     - The response, sampled on the accepting edge.

Integration notes
-----------------

* Decode ``PSEL`` in the interconnect; the block answers every transfer it
  is selected for.
* A register block that wants to signal an unmapped address drives
  ``reg_error`` for it; the block itself does no address decoding.
* Read side effects - popping a FIFO on a data-register read - belong on
  ``reg_valid && reg_ready && !reg_write``, which happens exactly once per
  transfer.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_apb_slave.py``
     - An APB4 requester and a register block written from the
       specifications, stepped cycle by cycle. Checks the reset state,
       zero-wait transfers at the minimum cycle count, wait states, PSLVERR,
       byte strobes, back-to-back transfers, a reset mid-transfer and 1500
       random transfers - and on every transfer exactly one request, its
       fields, its response and the mode's latency. Run at the registered
       parameters and, by hand, at ``REGISTERED=0`` and 8- and 16-bit data.
   * - ``tb/tb_apb_slave.sv``
     - Both modes side by side, each behind its own register block with
       pseudo-random wait states and an error word.
   * - ``formal/apb_slave_formal.sv``
     - k-induction proof of both response modes against an APB4
       requester: one register request per transfer, payload, response and
       wait-state timing.

.. code-block:: bash

   ctest --test-dir build -R 'apb_slave'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration. The
register response is reported as its own path group by
``scripts/apb_slave.sdc``: with ``REGISTERED=0`` it is a combinational path
partly outside the block, and the one that sets the bus frequency.
