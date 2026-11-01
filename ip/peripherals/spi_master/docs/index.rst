.. _ip-spi_master:

==========
spi_master
==========

SPI master with run-time mode and bit order, a programmable SCLK rate and
multi-word chip-select framing.

Functional description
======================

Each word handed in on the ``s_`` stream is exchanged full duplex:
``DATA_WIDTH`` bits go out on ``mosi`` while ``DATA_WIDTH`` bits come in on
``miso``, and the received word is presented on ``m_valid`` / ``m_data`` —
one pulse per word — when the exchange completes.

Modes
-----

``cpol`` is the SCLK idle level. With ``cpha = 0`` data is set up before the
leading edge, sampled on it and changed on the trailing edge; the first bit is
on ``mosi`` half a period before the first edge. With ``cpha = 1`` data changes
on the leading edge and is sampled on the trailing edge. ``lsb_first`` selects
the bit order on the wire.

.. list-table::
   :header-rows: 1
   :widths: 12 12 12 64

   * - Mode
     - cpol
     - cpha
     - Sample / shift
   * - 0
     - 0
     - 0
     - sample on rising, shift on falling
   * - 1
     - 0
     - 1
     - shift on rising, sample on falling
   * - 2
     - 1
     - 0
     - sample on falling, shift on rising
   * - 3
     - 1
     - 1
     - shift on falling, sample on rising

All three are inputs, not parameters, so one instance can talk to devices in
different modes on a shared bus. They are read while the block is idle and
must not change while ``busy`` is high.

Edges and timing
----------------

Every word produces exactly ``2 * DATA_WIDTH`` SCLK edges, ``clk_div`` clock
cycles apart, and SCLK finishes at its idle level. The first edge comes half a
period after ``cs_n`` falls, and ``cs_n`` stays low for half a period after the
last edge. A word therefore takes ``(2 * DATA_WIDTH + 2) * clk_div`` cycles.

Getting the edge count exactly right is the whole job. The implementation this
block replaces produced seven edges for an eight-bit word: its own receive
path sampled the last bit internally and looked correct, while a real slave,
which needs the edge, lost it.

Framing
-------

``s_last`` marks the final word of a chip-select frame. After it ``cs_n``
rises and stays high for at least half a period before the next frame. After
a word without ``s_last``, ``cs_n`` stays low and SCLK idles until the next
word arrives, so a command, an address and a data phase can be sent as one
frame however long the host takes to supply them — which is what flash
memories and most sensors require.

``miso`` timing
---------------

``miso`` is sampled on the clock edge that produces the sampling SCLK edge.
The slave changed it on the previous shift edge, so the round trip — clock to
the SCLK pad, board, slave clock-to-out, board, ``miso`` pad — has one SCLK
half period, ``clk_div`` cycles, to complete. ``miso`` is not synchronised: it
is synchronous to the SCLK this block generates, and is constrained as a
multicycle path rather than treated as asynchronous.

Block diagram
=============

.. code-block:: text

   s_data/s_last ==> IDLE/HOLD --accept--> SETUP --> SHIFT (2*W edges) --> FINISH
                                             |          |                    |
                         half-period counter (clk_div)  |                    v
                                                        |          m_valid/m_data
                     sample edge: rx_shift <= miso      |          s_last ? CS_HIGH
                     shift edge:  mosi <= tx_shift      |                  : HOLD
                                                        v
                                               sclk (toggles), cs_n

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
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 8
     - >= 2
     - Bits per word.
   * - ``DIV_WIDTH``
     - ``int unsigned``
     - 8
     - >= 1
     - Width of ``clk_div``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 18 8 14 60

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``, ``rst_n``
     - in
     - 1
     - Clock and active-low asynchronous reset.
   * - ``cpol``, ``cpha``, ``lsb_first``
     - in
     - 1
     - Mode and bit order; change only while idle.
   * - ``clk_div``
     - in
     - ``DIV_WIDTH``
     - SCLK half period in clock cycles, >= 1.
   * - ``s_valid`` / ``s_ready`` / ``s_data`` / ``s_last``
     - in / out / in / in
     - 1 / 1 / ``DATA_WIDTH`` / 1
     - Words to send; ``s_last`` ends the chip-select frame.
   * - ``m_valid`` / ``m_data``
     - out
     - 1 / ``DATA_WIDTH``
     - Received word, one pulse per word.
   * - ``busy``
     - out
     - 1
     - A frame is in progress.
   * - ``sclk``, ``mosi``, ``cs_n``
     - out
     - 1
     - SPI bus outputs, all registered.
   * - ``miso``
     - in
     - 1
     - SPI data from the slave.

Integration notes
-----------------

* Several slaves: decode ``cs_n`` with a select register; the block itself
  drives one chip select.
* ``m_valid`` has no back-pressure. A consumer that may stall needs a
  ``fifo_sync`` in front of it.
* Quad and dual SPI are not supported; they change the data path, not only
  the timing.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_spi_master.py``
     - A mode-aware SPI slave written from the mode definitions, sampling the
       bus every clock: it checks every word in both directions and measures
       the half period, the setup of ``mosi`` before each sampling edge, the
       ``cs_n`` high time and the edge count of every frame. Covers the reset
       state, all four modes in both bit orders, ``clk_div`` of 1, 5 and the
       maximum, multi-word frames held across host gaps, back-to-back frames
       and 40 randomised frames.
   * - ``tb/tb_spi_master.sv``
     - A 12-bit build with ``mosi`` echoed to ``miso``: every mode and bit
       order, three-word frames, the edge count of every frame and the SCLK
       idle level.

Reintroducing the previous implementation's defect — finishing one edge
early — fails both suites.

.. code-block:: bash

   ctest --test-dir build -R 'spi_master'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration. The critical
path is the half-period counter and the state decode. The ``miso`` input path
is described in ``scripts/spi_master.sdc``.
