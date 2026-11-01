.. _ip-i2c_master:

==========
i2c_master
==========

I2C bus master driven by byte-level commands, with clock stretching and
multi-master arbitration.

Functional description
======================

Commands
--------

The host issues one command at a time on the ``s_`` stream and receives one
response per command on ``m_valid``. A transaction is a sequence of commands:

.. list-table::
   :header-rows: 1
   :widths: 14 10 76

   * - Command
     - s_cmd
     - Effect and response
   * - START
     - 0
     - START, or repeated START inside a transaction.
   * - STOP
     - 1
     - STOP; the bus is released.
   * - WRITE
     - 2
     - Eight bits of ``s_data`` out, MSB first, then the slave's acknowledge,
       returned in ``m_nack`` (0 = ACK).
   * - READ
     - 3
     - Eight bits in, returned in ``m_data``, then the master's acknowledge:
       ``s_nack = 1`` for the last byte of a read.

Leaving the sequencing to the host keeps the block small and covers every
device — register pointers, repeated starts, 10-bit addresses — without the
block knowing about any of them. A register read is
``START, WRITE addr|0, WRITE reg, START, WRITE addr|1, READ..., READ(nack),
STOP``.

Bus
---

The lines are open drain. ``scl_oe`` / ``sda_oe`` high pull the line low; low
releases it to the pull-up. Both are flop outputs, so the pads never see a
glitch. ``scl_i`` / ``sda_i`` are the line levels, asynchronous because another
master or a stretching slave can move them, and are synchronised before use.

Bit timing
----------

Every bit is four phases of ``clk_div`` clock cycles. SCL is low in the first
and last and released in the middle two, so the SCL period is ``4 * clk_div``
cycles: 100 kHz from 100 MHz is ``clk_div = 250``. Data changes only while SCL
is low; START (SDA falling with SCL high) and STOP (SDA rising with SCL high)
are the two deliberate exceptions.

Clock stretching
----------------

A phase in which SCL is released does not start counting until the line is
seen high. A slave holding SCL low therefore simply lengthens the phase. The
same mechanism absorbs the bus rise time and the synchroniser delay, so the SCL
high time is never shorter than ``2 * clk_div`` cycles, however slow the bus.

Arbitration
-----------

A master that releases SDA and reads it low has lost to another master
driving a 0. The check is made in the middle of the high time of every bit the
master sends as a 1, before a START, and two phases after the STOP edge. On a
loss the master releases both lines at once, abandons the command and returns
``m_arb_lost``; the host must wait for the bus to be idle and retry.

Divider floor
-------------

SDA released for STOP is checked two phases later, so ``2 * clk_div`` must
cover the bus rise time plus ``SYNC_STAGES + 1`` cycles of synchroniser delay.
Below that the master would report a STOP lost to nobody; an assertion catches
it. Real rates are far above the floor.

Block diagram
=============

.. code-block:: text

   s_cmd/s_data/s_nack ==> command -> bit sequence
                             START: [S]   STOP: [P]
                             WRITE: 8 x W(bit) + R(ack)
                             READ:  8 x R      + W(nack)
                                         |
                                four phases x clk_div
                                (released-SCL phases wait for scl high)
                                         |
                    scl_oe / sda_oe <====+====> sample / arbitration
                                                    ^
   scl_i, sda_i --> cdc_sync_2ff --> scl_s, sda_s --+
                                         |
                                  m_valid/m_data/m_nack/m_arb_lost

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
   * - ``DIV_WIDTH``
     - ``int unsigned``
     - 16
     - >= 2
     - Width of ``clk_div``.
   * - ``SYNC_STAGES``
     - ``int unsigned``
     - 2
     - >= 2
     - Line synchroniser depth.

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
   * - ``clk_div``
     - in
     - ``DIV_WIDTH``
     - Quarter SCL period in clock cycles; see the floor. Change only while
       idle.
   * - ``s_valid`` / ``s_ready``
     - in / out
     - 1
     - Command handshake.
   * - ``s_cmd``, ``s_data``, ``s_nack``
     - in
     - 2, 8, 1
     - Command, byte to write, acknowledge to send after a read.
   * - ``m_valid``
     - out
     - 1
     - One pulse per command.
   * - ``m_data``, ``m_nack``, ``m_arb_lost``
     - out
     - 8, 1, 1
     - Byte read; slave acknowledge of a write; arbitration lost.
   * - ``busy``
     - out
     - 1
     - A command is in progress.
   * - ``scl_i``, ``sda_i``
     - in
     - 1
     - Line levels, asynchronous.
   * - ``scl_oe``, ``sda_oe``
     - out
     - 1
     - Pull the line low when high.

Integration notes
-----------------

* At the pad: ``assign scl = scl_oe ? 1'b0 : 1'bz; assign scl_i = scl;`` and
  the same for SDA, with an external pull-up.
* The block does not detect a busy bus before its first START. In a
  multi-master system, wait for a STOP (or a bus-idle timeout) before issuing
  one; arbitration then resolves simultaneous starts.
* Bus recovery after a slave is left holding SDA — nine clocks with SDA
  released — is a host sequence of READ commands followed by STOP.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_i2c_master.py``
     - An open-drain bus model with an EEPROM-style slave written from the
       protocol and a monitor that checks SCL low and high times on every
       clock. Covers the reset state, a register write and a read-back with
       a repeated START, an unowned address, a slave stretching every
       acknowledge, the fastest legal divider, arbitration lost to another
       master, and randomised transactions at random rates against the
       slave's memory. Every command on the single-master bus is checked for
       a false arbitration loss.
   * - ``tb/tb_i2c_master.sv``
     - Its own behavioural slave: block write, read-back with a repeated
       START, and an unowned address, at two SCL rates.

.. code-block:: bash

   ctest --test-dir build -R 'i2c_master'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration. The critical
path is the quarter-period counter and the line-level decode. ``scl_i`` and
``sda_i`` go straight into a synchroniser; their input paths are cut in
``scripts/i2c_master.sdc``.
