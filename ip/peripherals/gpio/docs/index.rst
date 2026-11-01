.. _ip-gpio:

====
gpio
====

General-purpose I/O port with per-pin direction, atomic set/clear,
synchronised inputs and edge interrupts.

Functional description
======================

Each of the ``WIDTH`` pins is independently an input or an output. The block
presents the three signals a pad needs — ``pin_out``, ``pin_oe`` and
``pin_in`` — and leaves the tri-state buffer to the pad ring, so nothing in it
is technology specific.

Inputs
------

``pin_in`` is asynchronous to ``clk``. Every bit passes through a
``cdc_sync_2ff`` stage before anything reads it, so ``IN`` lags the pad by
``SYNC_STAGES`` cycles and an edge event by one more. Each pin is synchronised
on its own: the pins are independent signals and ``IN`` is a set of
independent samples, not a coherent word. Two pins that change together on the
board may be seen a cycle apart. Software that needs several pins sampled as a
unit has to arrange that externally, for example with a strobe pin.

Outputs
-------

``pin_out`` carries ``OUT`` unmasked by ``DIR``; the pad drives only when
``pin_oe`` is high. Keeping the two separate means software can preload a
value and then turn the pin into an output, so the pad never glitches to the
reset value on the way.

``OUT_SET`` and ``OUT_CLR`` change only the bits written as one. They exist so
that two agents — an interrupt handler and the main loop, say — can each drive
their own pins without a read-modify-write race on ``OUT``.

Interrupts
----------

``RISE_EN`` and ``FALL_EN`` select, per pin, which edges of the synchronised
input latch a bit in ``STATUS``. ``irq`` is high while any ``STATUS`` bit is
set; writing a one to a ``STATUS`` bit clears it. An event in the same cycle as
the clear of its bit wins and the bit stays set: a spurious interrupt costs a
handler invocation, a lost one can cost a system.

The enables come out of reset clear, so a pin already high when reset is
released — which the synchroniser sees as a rising edge as it fills — never
raises an interrupt.

Register map
============

The read port is combinational: ``rd_data`` reflects ``addr`` in the same
cycle. Writes take effect on the next edge.

.. list-table::
   :header-rows: 1
   :widths: 8 14 10 68

   * - addr
     - Name
     - Access
     - Description
   * - 0
     - ``OUT``
     - rw
     - Output value of every pin.
   * - 1
     - ``DIR``
     - rw
     - 1 = output (``pin_oe`` high), 0 = input.
   * - 2
     - ``IN``
     - ro
     - Synchronised pin value. Outputs read back their pad level.
   * - 3
     - ``OUT_SET``
     - wo
     - ``OUT |= wr_data``. Reads 0.
   * - 4
     - ``OUT_CLR``
     - wo
     - ``OUT &= ~wr_data``. Reads 0.
   * - 5
     - ``RISE_EN``
     - rw
     - Latch a ``STATUS`` bit on a rising edge of the pin.
   * - 6
     - ``FALL_EN``
     - rw
     - Latch a ``STATUS`` bit on a falling edge of the pin.
   * - 7
     - ``STATUS``
     - rw1c
     - Latched edge events. Write 1 to clear.

Block diagram
=============

.. code-block:: text

   pin_in ==> cdc_sync_2ff ==> in_sync ==+==> IN
                                         |
                              in_prev <==+   rise = in & ~prev
                                             fall = ~in & prev
                                                  |
                       RISE_EN / FALL_EN ---------+--> STATUS (set beats clear)
                                                          |
                                                          +--> irq = |STATUS

   wr_en/addr/wr_data --> OUT, DIR, RISE_EN, FALL_EN, OUT_SET/CLR, STATUS W1C
   OUT ==> pin_out        DIR ==> pin_oe        addr --> read mux ==> rd_data

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
   * - ``WIDTH``
     - ``int unsigned``
     - 8
     - 1 to 32
     - Number of pins.
   * - ``SYNC_STAGES``
     - ``int unsigned``
     - 2
     - >= 2
     - Input synchroniser depth.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 8 12 64

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
   * - ``addr``
     - in
     - 3
     - Register address for both reads and writes.
   * - ``wr_en``
     - in
     - 1
     - Write ``wr_data`` to ``addr`` on this edge.
   * - ``wr_data``
     - in
     - ``WIDTH``
     - Write data.
   * - ``rd_data``
     - out
     - ``WIDTH``
     - Register at ``addr``, combinational.
   * - ``pin_in``
     - in
     - ``WIDTH``
     - Pad input levels, asynchronous.
   * - ``pin_out``
     - out
     - ``WIDTH``
     - Pad output values.
   * - ``pin_oe``
     - out
     - ``WIDTH``
     - Pad output enables.
   * - ``irq``
     - out
     - 1
     - Level interrupt: any ``STATUS`` bit set.

Integration notes
-----------------

* The register port maps directly onto an APB or AXI4-Lite slave: decode the
  address, pass ``wr_en`` on a write strobe, return ``rd_data``.
* ``irq`` is a level. Clear the cause in the handler before returning, or the
  interrupt is taken again.
* The synchroniser does not debounce. A mechanical switch needs a debouncer
  in front, or a timer in software.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_gpio.py``
     - A cycle-accurate model with its own synchroniser pipeline, written from
       the register map and compared after every edge against ``rd_data``,
       ``pin_out``, ``pin_oe`` and ``irq``. Covers the reset state, read-back
       of every register, write-only and read-only behaviour, atomic set and
       clear, direction independent of value, the exact input latency, edge
       interrupts and write-1-to-clear, pins high at reset release, an event
       arriving on the same edge as its clear, and 3000 cycles of random
       register traffic with toggling pins.
   * - ``tb/tb_gpio.sv``
     - Portable self-checking testbench with the same model in
       SystemVerilog and 4000 randomised cycles.

.. code-block:: bash

   ctest --test-dir build -R 'gpio'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration. The longest
paths are the address decode into the register enables and the read mux, both
shallow. The paths from ``pin_in`` into the first synchroniser stage are
asynchronous and are cut in ``scripts/gpio.sdc``.
