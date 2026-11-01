.. _ip-clk_divider:

===========
clk_divider
===========

Integer clock divider producing both a divided clock and the equivalent clock
enable.

Functional description
======================

The block counts source clock cycles and produces two outputs from the same
counter. They solve the same problem in different ways, and the right choice
depends on the target.

``clk_en`` — the preferred output
---------------------------------

A single-cycle enable pulse in the *source* clock domain, asserted once every
``DIVISOR`` cycles. Registers that should run at the divided rate are simply
enabled by it:

.. code-block:: systemverilog

   always_ff @(posedge clk or negedge rst_n) begin
     if (!rst_n)      counter_q <= '0;
     else if (clk_en) counter_q <= counter_q + 1;
   end

The whole design stays in one clock domain. Static timing analysis sees one
clock, there is no clock domain crossing to constrain, and no clock tree
resource is consumed. On an FPGA, clock resources are a scarce global resource;
on an ASIC, every extra clock tree is area, power and another set of skew
constraints. Use this output unless something genuinely needs a slower edge.

``clk_out`` — a real divided clock
----------------------------------

A true divided clock with a 50% duty cycle for every ``DIVISOR >= 2``. Use it
only when a slower clock edge is unavoidable: driving an external device that
expects a clock pin, or feeding a block that has no enable input. It is a
generated clock and must be declared as such in the SDC.

Why odd divisors are harder
---------------------------

A 50% duty cycle at an odd ``DIVISOR`` cannot be produced from the rising edge
alone. Dividing by five means a period of five source cycles, so each half must
be two and a half — and a rising-edge flip-flop can only change on integer
cycle boundaries. The best it can do is 3/2 or 2/3, which is a 60% or 40% duty
cycle.

The odd case therefore builds two phases. The rising-edge phase is high for
``(DIVISOR+1)/2`` source cycles. The falling-edge phase is the same waveform
delayed by exactly half a source period. ANDing them removes half a source
period from the high time:

.. math::

   \frac{DIVISOR+1}{2} - \frac{1}{2} = \frac{DIVISOR}{2}

which is a true 50% duty cycle. The cost is one negative-edge flip-flop, so the
even case — which needs no such trick — is generated without it and does not
pay for it.

``DIVISOR = 1`` is specialised to a pass-through. Building a counter for it
would cost area and add a clock tree for no reason.

Block diagram
=============

.. code-block:: text

                  +---------------------------------------------+
                  |                                             |
    clk    ------>|  +-------------+                            |
                  |  | count_q     |--- wrap ---+-------------->|--> clk_en
    enable ------>|  | 0..DIVISOR-1|            |               |    (& enable)
                  |  +-------------+            |               |
    rst_n  ------>|         |                   v               |
                  |         |          +------------------+     |
                  |         +--------->| even: toggle FF  |     |
                  |                    |  at DIVISOR/2    |---->|--> clk_out
                  |                    +------------------+     |
                  |                              or             |
                  |                    +------------------+     |
                  |                    | odd: rise phase  |     |
                  |                    |  AND fall phase  |     |
                  |                    +------------------+     |
                  +---------------------------------------------+

Timing diagram
==============

``DIVISOR = 5``, so the divided period is five source periods and each half is
two and a half:

.. code-block:: text

              .  .  .  .  .  .  .  .  .  .  .  .
   clk     __/‾\/‾\/‾\/‾\/‾\/‾\/‾\/‾\/‾\/‾\/‾\/‾\__
              .  .  .  .  .  .  .  .  .  .  .  .
   count    0  1  2  3  4  0  1  2  3  4  0  1  2
              .  .  .  .  .  .  .  .  .  .  .  .
   clk_en  ____________/‾‾\___________/‾‾\________   one pulse per 5 cycles
              .  .  .  .  .  .  .  .  .  .  .  .
   clk_out ___/‾‾‾‾‾‾‾\______/‾‾‾‾‾‾‾\______/‾‾‾‾   2.5 high, 2.5 low
              .  .  .  .  .  .  .  .  .  .  .  .
              |<-2.5->|<-2.5->|

Note that ``clk_en`` marks the final source cycle of each divided period, so a
register enabled by it updates on the same edge that ``clk_out`` rises. The two
outputs are always in step.

``DIVISOR = 4``, the even case:

.. code-block:: text

              .  .  .  .  .  .  .  .  .  .
   clk     __/‾\/‾\/‾\/‾\/‾\/‾\/‾\/‾\/‾\/‾\__
              .  .  .  .  .  .  .  .  .  .
   count    0  1  2  3  0  1  2  3  0  1
              .  .  .  .  .  .  .  .  .  .
   clk_en  _________/‾‾\_________/‾‾\______
              .  .  .  .  .  .  .  .  .  .
   clk_out ___/‾‾‾‾‾\_____/‾‾‾‾‾\_____/‾‾‾   2 high, 2 low

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 16 20 12 12 40

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``DIVISOR``
     - ``int unsigned``
     - 2
     - >= 1
     - Division ratio. ``1`` passes the clock through unchanged. Even ratios
       cost one counter and one toggle flip-flop; odd ratios add one
       negative-edge flip-flop.

``DIVISOR < 1`` is rejected at elaboration with ``$fatal``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 14 8 8 70

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``
     - in
     - 1
     - Source clock.
   * - ``rst_n``
     - in
     - 1
     - Active-low reset, asserted asynchronously and released synchronously.
   * - ``enable``
     - in
     - 1
     - Synchronous enable. Deasserting it parks both outputs in their reset
       state and restarts the counter from zero; it does not merely pause.
   * - ``clk_en``
     - out
     - 1
     - One source-clock cycle wide, once every ``DIVISOR`` source cycles.
   * - ``clk_out``
     - out
     - 1
     - Divided clock, 50% duty cycle for ``DIVISOR >= 2``.

Usage examples
==============

Preferred: a clock enable
-------------------------

.. code-block:: systemverilog

   clk_divider #(.DIVISOR(100)) u_tick_1mhz (
     .clk     (clk_100mhz),
     .rst_n   (rst_n),
     .enable  (1'b1),
     .clk_en  (tick_1mhz),
     .clk_out ()                     // unused; synthesis removes the logic
   );

   always_ff @(posedge clk_100mhz or negedge rst_n) begin
     if (!rst_n)         micros_q <= '0;
     else if (tick_1mhz) micros_q <= micros_q + 1;
   end

A real divided clock for an external device
-------------------------------------------

.. code-block:: systemverilog

   clk_divider #(.DIVISOR(8)) u_spi_clk (
     .clk     (clk_sys),
     .rst_n   (rst_n),
     .enable  (spi_active),
     .clk_en  (),
     .clk_out (spi_sclk)             // leaves the chip
   );

Gating the divider
------------------

``enable`` stops the divider cleanly and restarts it from a known phase, which
is what makes the output predictable after a gap:

.. code-block:: systemverilog

   clk_divider #(.DIVISOR(5)) u_div (
     .clk     (clk_sys),
     .rst_n   (rst_n),
     .enable  (subsystem_powered),
     .clk_en  (subsystem_tick),
     .clk_out (clk_subsystem)
   );

Integration notes
-----------------

* If ``clk_out`` is used, it **must** be declared as a generated clock. Without
  that declaration the entire divided domain is untimed and will pass static
  timing analysis while being broken.
* The odd-divisor implementation uses a negative-edge flip-flop. That is
  intentional and portable, but it does mean the source clock's duty cycle
  affects the output's: a source clock that is not 50% duty produces an output
  that is not 50% either. Where that matters, use an even divisor.
* ``clk_en`` is combinational from ``enable`` and the counter's terminal count.
  Where the enable path is timing critical, register it in the consumer.

Verification
============

The duty cycle is *measured* from real simulation timestamps, not inferred from
a model. An odd divisor invites a duty cycle wrong by half a source period, and
only a measurement catches that.

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_clk_divider.py``
     - Parked state while disabled; exactly one ``clk_en`` pulse per
       ``DIVISOR`` cycles; the high and low phases of ``clk_out`` measured
       over twelve consecutive periods; disable and re-enable; randomised
       enable toggling across 25 windows; and a 200-period run confirming the
       divided period accumulates no drift. Run at both an odd and an even
       divisor.
   * - ``tb/tb_clk_divider.sv``
     - Portable smoke test measuring high and low phases with ``$realtime``.

.. code-block:: bash

   ctest --test-dir build -R 'clk_divider'
