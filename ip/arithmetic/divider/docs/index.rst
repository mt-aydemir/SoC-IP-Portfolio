.. _ip-divider:

=======
divider
=======

Sequential restoring divider producing quotient and remainder, signed or
unsigned, with ready/valid interfaces.

Functional description
======================

The block accepts a dividend and a divisor over a ready/valid handshake,
computes the quotient and the remainder one bit per cycle, and presents both
over a second ready/valid handshake together with two status flags.

Division is the one basic arithmetic operation with no cheap combinational
form. A single-cycle divider is an enormous amount of logic and sets the clock
period for the whole design, so this block is sequential: it consumes one bit
of quotient per cycle and takes ``WIDTH`` iterations per division. That is the
trade every practical divider makes.

Algorithm
---------

Restoring shift-subtract — the long division taught in school, written in
binary. Each iteration shifts the working remainder and the quotient left by
one, then tries to subtract the divisor:

.. code-block:: text

   {remainder, quotient} <<= 1
   if (remainder >= divisor) { remainder -= divisor; quotient[0] = 1; }

"Restoring" refers to how the trial subtraction is handled: the value is only
committed when it does not go negative, so nothing has to be undone.

The comparison and the subtraction share one adder. The trial subtraction is
one bit wider than the operands, and its top bit *is* the comparison. That
shortcut rests on the algorithm's invariant, ``remainder < divisor`` after
every iteration: it bounds the shifted remainder below twice the divisor, so a
successful trial leaves a value below the divisor with the top bit clear, and
an unsuccessful one goes negative and sets it. The same invariant is why the
*stored* remainder needs only ``WIDTH`` bits — a ``WIDTH+1``\ st bit there
would be a flip-flop that is provably always zero.

Signed division
---------------

Signed division is performed on magnitudes and the signs applied afterwards,
because the shift-subtract recurrence is only valid for non-negative values.

The result follows the **truncated** convention that C and SystemVerilog both
use: the quotient rounds towards zero, and the remainder takes the sign of the
*dividend*.

.. list-table::
   :header-rows: 1
   :widths: 25 25 25 25

   * - Dividend
     - Divisor
     - Quotient
     - Remainder
   * - 7
     - 2
     - 3
     - 1
   * - −7
     - 2
     - −3
     - −1
   * - 7
     - −2
     - −3
     - 1
   * - −7
     - −2
     - 3
     - −1

The identity ``dividend == quotient * divisor + remainder`` holds under either
rounding convention; only the direction differs. The distinction matters in
practice because Python's ``//`` and ``%`` floor instead, so a reference model
written with them would disagree with every processor in existence. The cocotb
suite adjusts for exactly this.

Special cases
-------------

Two inputs have no arithmetic answer and are handled by convention. Both
complete without iterating, so their latency is two cycles rather than
``WIDTH + 2``.

**Division by zero** raises ``div_by_zero`` and returns an all-ones quotient
with the dividend, untouched, as the remainder. That is what most processors
do, and it means software that ignores the flag gets a recognisable value
rather than a stale one.

**most-negative / −1** in the signed configuration raises ``overflow``: the
true quotient is the magnitude of the most negative value, which is one larger
than the most positive representable value. The wrapped result —
most-negative, remainder zero — is returned, and the flag says not to trust it.

Block diagram
=============

.. code-block:: text

                +---------------------------------------------------------+
   s_valid ---->|  S_IDLE  --s_valid-->  S_ITERATE x WIDTH  -->  S_PRESENT |
   s_ready <----|    ^       (or straight to S_PRESENT for /0, MIN/-1)  |  |
                |    +-------------------------- m_ready ---------------+  |
                |                                                         |
   dividend ===>| |magnitude| --> quot_q  -----+                          |
   divisor  ===>| |magnitude| --> divisor_q    |                          |
                |                    |         v                          |
                |                    |   {rem_q, quot_q[MSB]}  [W+1]      |
                |                    +------> (-) --> trial               |
                |                              |                          |
                |                    trial[W] == 0 ? commit : keep        |
                |                              |                          |
                |   rem_q, quot_q <------------+                          |
                |                                                         |
                |   apply signs / special-case conventions                |
   quotient  <==|=========================================================|
   remainder <==|=========================================================|
   div_by_zero<-|---------------------------------------------------------|
   overflow  <--|---------------------------------------------------------|
   m_valid   <--|  (state == S_PRESENT)                                   |
   m_ready   -->|                                                         |
                +---------------------------------------------------------+

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 18 14 10 16 42

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``WIDTH``
     - ``int unsigned``
     - 32
     - >= 2
     - Operand width, and the number of iterations per division.
   * - ``SIGNED``
     - ``int unsigned``
     - 0
     - 0 or 1
     - Interpret both operands as two's complement, with truncated rounding.

Illegal parameter values are rejected at elaboration with ``$fatal``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 10 12 62

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
     - Active-low reset. Asserted asynchronously, released synchronously.
       Abandons any division in progress.
   * - ``s_valid``
     - in
     - 1
     - The operands are valid. Must be held, with stable operands, until
       ``s_ready``.
   * - ``s_ready``
     - out
     - 1
     - The divider is idle and accepts operands this cycle.
   * - ``dividend``
     - in
     - ``WIDTH``
     - Dividend.
   * - ``divisor``
     - in
     - ``WIDTH``
     - Divisor.
   * - ``m_valid``
     - out
     - 1
     - The result is valid. Held, with stable outputs, until ``m_ready``.
   * - ``m_ready``
     - in
     - 1
     - The sink accepts the result this cycle.
   * - ``quotient``
     - out
     - ``WIDTH``
     - Quotient, rounded towards zero.
   * - ``remainder``
     - out
     - ``WIDTH``
     - Remainder, with the sign of the dividend.
   * - ``div_by_zero``
     - out
     - 1
     - The divisor was zero.
   * - ``overflow``
     - out
     - 1
     - Signed most-negative / −1: the quotient is not representable.

Protocol
--------

Both interfaces follow AXI4-Stream rules: a transfer happens on any rising
edge where ``valid`` and ``ready`` are both high, and once ``valid`` is
asserted it stays asserted with stable payload until the transfer. Both halves
are checked by concurrent assertions in the RTL, so a violation by the
surrounding logic is reported in the integrator's own simulation.

The divider is not pipelined: ``s_ready`` is low from the cycle after a
request is accepted until the cycle after its result is taken.

Usage examples
==============

A processor's divide unit
-------------------------

.. code-block:: systemverilog

   divider #(
     .WIDTH  (32),
     .SIGNED (1)
   ) u_div (
     .clk         (clk),
     .rst_n       (rst_n),
     .s_valid     (ex_is_div & ex_valid),
     .s_ready     (div_ready),
     .dividend    (rs1_value),
     .divisor     (rs2_value),
     .m_valid     (div_done),
     .m_ready     (wb_ready),
     .quotient    (div_quotient),
     .remainder   (div_remainder),
     .div_by_zero (div_by_zero),
     .overflow    (div_overflow)
   );

Integration notes
-----------------

* The latency is data-dependent only in the two special cases. A caller that
  counts cycles instead of waiting for ``m_valid`` will mis-time exactly the
  inputs that matter most.
* For throughput beyond one division per ``WIDTH + 2`` cycles, instantiate
  several dividers behind an arbiter; the block is deliberately not pipelined,
  because a pipelined divider costs ``WIDTH`` adders.
* Use the unsigned configuration for unsigned data. Running unsigned values
  through the signed configuration halves the usable range and changes the
  rounding of values with the top bit set.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_divider.py``
     - Exact division, division with a remainder, division by one, a zero
       dividend, division by zero, the signed overflow case, corner-biased
       randomised operands against Python arithmetic adjusted to the
       truncated convention, an exhaustive sweep at narrow widths,
       back-to-back requests, and the identity
       ``dividend == quotient * divisor + remainder``.
   * - ``tb/tb_divider.sv``
     - Portable self-checking testbench against SystemVerilog's own ``/`` and
       ``%``: the four sign combinations, the special cases, a result held
       unchanged through five stalled cycles, a sweep of the operand space at
       ``WIDTH=8``, and randomised operands with random result stalls.

.. code-block:: bash

   ctest --test-dir build -R 'divider'

Timing
======

The block is timed by OpenSTA on its synthesised netlist at the clock period
in its ``add_ip()`` registration. The critical path is one ``WIDTH+1``-bit
subtraction plus the commit multiplexer — the reason the block is sequential
at all — followed at the output by the sign-application negation, which is
combinational from the registers to the result ports.
