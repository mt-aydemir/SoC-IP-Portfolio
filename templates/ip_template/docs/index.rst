.. _ip-template_ip:

===========
template_ip
===========

One-sentence summary of the block, used as its entry in the IP catalogue.

Functional description
======================

What the block does, the algorithm it implements, and the design decisions an
integrator needs to understand. State the latency, the throughput, the reset
behaviour and what happens under back-pressure.

The template implements a single registered stage on a ready/valid stream. A
word presented at the input appears at the output one clock later, and the
input stalls whenever the output is occupied and the sink is not accepting.

Block diagram
=============

.. code-block:: text

                  +----------------------------------+
    s_valid  ---->|                                  |----> m_valid
    s_ready  <----|          template_ip             |<---- m_ready
    s_data   ====>|                                  |====> m_data
      [W]         |   +--------------------------+   |        [W]
                  |   |  payload register  [W]   |   |
                  |   +--------------------------+   |
                  |   s_ready = m_ready | !m_valid   |
                  +----------------------------------+
                            ^              ^
                            |              |
                           clk           rst_n

Timing diagram
==============

A single transfer, followed by a stalled transfer where the sink withholds
``m_ready`` for two cycles:

.. code-block:: text

               .    .    .    .    .    .    .    .
    clk     __/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__
               .    .    .    .    .    .    .    .
    s_valid ___/‾‾‾‾‾\___/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\__________
               .    .    .    .    .    .    .    .
    s_ready ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\___________/‾‾‾‾‾‾‾‾‾
               .    .    .    .    .    .    .    .
    s_data  ---< D0  >-------< D1                >---
               .    .    .    .    .    .    .    .
    m_valid _________/‾‾‾‾‾\_______/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_
               .    .    .    .    .    .    .    .
    m_ready ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_________/‾‾‾‾‾‾‾‾‾‾‾
               .    .    .    .    .    .    .    .
    m_data  ---------< D0    >-----< D1          >---

Transfers occur where ``valid`` and ``ready`` are both high at a rising edge.
While ``m_valid`` is high and ``m_ready`` is low the payload is held unchanged
and ``s_ready`` is withdrawn, so no data is lost.

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 20 12 12 20 36

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 8
     - >= 1
     - Width of the payload on both stream interfaces.

Illegal parameter combinations are rejected at elaboration with ``$fatal``, so
a misconfiguration fails immediately rather than producing broken hardware.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 10 16 12 46

   * - Signal
     - Dir
     - Width
     - Domain
     - Description
   * - ``clk``
     - in
     - 1
     - ``clk``
     - Rising-edge clock for the whole block.
   * - ``rst_n``
     - in
     - 1
     - async
     - Active-low reset. Asserted asynchronously, released synchronously.
   * - ``s_valid``
     - in
     - 1
     - ``clk``
     - Input payload is valid.
   * - ``s_ready``
     - out
     - 1
     - ``clk``
     - The block will accept a word this cycle.
   * - ``s_data``
     - in
     - ``DATA_WIDTH``
     - ``clk``
     - Input payload.
   * - ``m_valid``
     - out
     - 1
     - ``clk``
     - Output payload is valid.
   * - ``m_ready``
     - in
     - 1
     - ``clk``
     - The sink accepts a word this cycle.
   * - ``m_data``
     - out
     - ``DATA_WIDTH``
     - ``clk``
     - Output payload.

Protocol
--------

A transfer occurs on any rising clock edge where ``valid`` and ``ready`` are
both high. Once ``valid`` is asserted it must remain asserted, with stable
payload, until the transfer completes. ``ready`` may be asserted and withdrawn
freely. Both halves of that contract are checked by concurrent assertions
inside the block, so a violation by the surrounding logic is reported in the
integrator's own simulation.

Usage examples
==============

Instantiation
-------------

.. code-block:: systemverilog

   template_ip #(
     .DATA_WIDTH (32)
   ) u_stage (
     .clk     (clk),
     .rst_n   (rst_n),
     .s_valid (up_valid),
     .s_ready (up_ready),
     .s_data  (up_data),
     .m_valid (dn_valid),
     .m_ready (dn_ready),
     .m_data  (dn_data)
   );

Integration notes
-----------------

* ``s_ready`` depends combinationally on ``m_ready``. If that combinational
  path is too long in the surrounding design, break it by placing a skid buffer
  downstream rather than by editing this block.
* ``rst_n`` must be released synchronously to ``clk``. Use ``cdc_reset_sync``
  once per clock domain, as described in :doc:`../../../integration`.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_template_ip.py``
     - Reset state, single transfer, back-to-back traffic, sink back-pressure,
       randomised corner-biased traffic against an in-order scoreboard,
       mid-stream reset, and a 2000-transfer sustained run.
   * - ``tb/tb_template_ip.sv``
     - Portable self-checking smoke test with randomised back-pressure.

.. code-block:: bash

   ctest --test-dir build -R 'template_ip'
