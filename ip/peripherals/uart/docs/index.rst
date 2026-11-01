.. _ip-uart:

====
uart
====

Full-duplex asynchronous serial transmitter and receiver with a run-time bit
period, optional parity and error reporting.

Functional description
======================

Frame format
------------

One start bit (low), ``DATA_BITS`` data bits least significant first, an
optional parity bit, then ``STOP_BITS`` stop bits (high). The line idles high.
Even parity makes the number of ones in data plus parity even; odd makes it
odd.

Bit period
----------

The bit period is an input, ``clks_per_bit``, rather than a parameter derived
from a clock frequency and a baud rate. The same netlist then serves every
baud rate, and the rounding of ``CLK_HZ / BAUD`` — whose error is what decides
whether a link works — stays with the integrator, who knows both numbers. It
must be at least 4 so the receiver can find the bit centre, and must not change
while either direction is busy; an assertion checks the first.

Transmitter
-----------

A word is accepted on ``s_valid && s_ready``, and ``txd`` goes low for the
start bit on the next edge. ``s_ready`` stays low for the whole frame. Every
bit lasts exactly ``clks_per_bit`` cycles; back-to-back words are separated by
one extra clock of stop level, so the stop period is ``STOP_BITS`` bit times
plus one clock, which every receiver accepts. ``txd`` is a flop output — the
bottom of the frame shift register — so it never glitches.

Receiver
--------

``rxd`` is synchronised, then a falling edge starts a frame. Half a bit later
the start bit is sampled again and the frame is abandoned if the line has gone
back high, so noise shorter than half a bit is not a character. Every later
bit is sampled at its centre, counted from the detected edge; the
synchroniser delay is the same for every edge and cancels out.

Only the first stop bit is checked. A receiver that demanded two would reject
a transmitter sending one and a half.

A completed character is presented on ``m_valid`` / ``m_data`` with
``m_parity_err`` and ``m_frame_err`` alongside, and held until ``m_ready``.

Errors
------

**Parity error**: the parity bit disagrees with the data. The character is
still delivered, flagged.

**Framing error**: the first stop bit is low. The character is delivered,
flagged, and the receiver then waits for the line to return high before it
looks for another start bit. Without that wait a break — the line held low
for longer than a frame, used by some protocols as a reset — would arrive as
an endless run of zero characters.

**Overrun**: a character completes while the previous one is still held.
The new one is dropped and ``rx_overrun`` pulses for a cycle. The held
character is kept because it is the one software is already reading.

Baud tolerance
--------------

Sampling at the centre leaves half a bit of margin, spent over the frame by
the rate mismatch between the two ends plus the one-clock uncertainty of
detecting the start edge. For a 10-bit frame and ``clks_per_bit`` of 16, a
mismatch of about 4 % in either direction is tolerated; the verification
checks 3 %.

Block diagram
=============

.. code-block:: text

   s_data ==> frame builder ==> tx_shift ==> txd   (tx_count: clks_per_bit)
   s_valid/s_ready <-- !tx_busy

   rxd --> cdc_sync_2ff --> rx_sync --> IDLE -> START (half bit, re-check)
                                         -> DATA (x DATA_BITS) -> PARITY
                                         -> STOP --> m_data / errors / overrun
                                         -> WAIT_HIGH after a framing error

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
   * - ``DATA_BITS``
     - ``int unsigned``
     - 8
     - 5 to 9
     - Data bits per character.
   * - ``PARITY``
     - ``int unsigned``
     - 0
     - 0, 1, 2
     - None, even, odd.
   * - ``STOP_BITS``
     - ``int unsigned``
     - 1
     - 1 or 2
     - Stop bits transmitted. The receiver checks one.
   * - ``DIV_WIDTH``
     - ``int unsigned``
     - 16
     - >= 3
     - Width of ``clks_per_bit``.
   * - ``SYNC_STAGES``
     - ``int unsigned``
     - 2
     - >= 2
     - ``rxd`` synchroniser depth.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 18 8 14 60

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``
     - in
     - 1
     - Rising-edge clock.
   * - ``rst_n``
     - in
     - 1
     - Active-low asynchronous reset.
   * - ``clks_per_bit``
     - in
     - ``DIV_WIDTH``
     - Bit period in clock cycles, >= 4.
   * - ``s_valid`` / ``s_ready`` / ``s_data``
     - in / out / in
     - 1 / 1 / ``DATA_BITS``
     - Transmit stream.
   * - ``txd``
     - out
     - 1
     - Serial output, idles high.
   * - ``m_valid`` / ``m_ready`` / ``m_data``
     - out / in / out
     - 1 / 1 / ``DATA_BITS``
     - Receive stream.
   * - ``m_parity_err``, ``m_frame_err``
     - out
     - 1
     - Errors of the character on ``m_data``.
   * - ``rx_overrun``
     - out
     - 1
     - One-cycle pulse: a character was dropped.
   * - ``rxd``
     - in
     - 1
     - Serial input, asynchronous.

Usage examples
==============

115200 baud from 50 MHz
-----------------------

``50e6 / 115200 = 434.03``, so ``clks_per_bit = 434`` with an error of
0.007 % — negligible. From 48 MHz the same rate is 416.67; 417 gives 0.08 %.
The rate to worry about is the one where the division leaves a large
fraction: 921600 baud from 50 MHz is 54.25, and 54 is 0.47 % fast.

Integration notes
-----------------

* There is no FIFO. Put a ``fifo_sync`` on either stream if software cannot
  service every character within one frame time.
* ``rx_overrun`` is a pulse; latch it in a status register if software needs
  to see it.
* Hardware flow control (RTS/CTS) is not included; it is two GPIO pins and a
  policy, and the policy belongs to the integrator.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_uart.py``
     - Line-level checkers: the transmit monitor samples ``txd`` every clock
       and requires each bit to hold for exactly ``clks_per_bit`` cycles; the
       receive driver produces frames from real-time delays unaligned to the
       clock. Covers the reset state, corner words in both directions,
       back-to-back transmission, parity and framing errors, a break, start
       glitches, overrun, the minimum and an odd bit period, a transmitter
       3 % fast and slow, and a randomised full-duplex loopback with random
       periods and receive back-pressure. Simulated with even parity.
   * - ``tb/tb_uart.sv``
     - A second geometry — 7 data bits, odd parity, two stop bits: one frame
       checked at its bit centres, injected parity and framing errors, and a
       random loopback at three bit periods.

.. code-block:: bash

   ctest --test-dir build -R 'uart'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration. The critical
paths are the ``DIV_WIDTH``-bit period counters. ``rxd`` goes straight into a
synchroniser and its input path is cut in ``scripts/uart.sdc``.
