.. _ip-cdc_sync_2ff:

============
cdc_sync_2ff
============

Multi-flop synchroniser for asynchronous single-bit signals.

Functional description
======================

The block transfers one or more *independent* asynchronous bits into the
destination clock domain through a chain of ``STAGES`` flip-flops.

When an asynchronous signal changes close to the sampling edge of the first
flip-flop, that flip-flop's setup or hold requirement is violated and its
output can settle to an intermediate voltage — it goes metastable. The state
resolves to a valid logic level after an unpredictable delay whose probability
distribution falls off exponentially with time. Each additional flip-flop in
the chain gives the resolution a further full clock period, so the mean time
between failures rises exponentially with ``STAGES``.

Two stages is the industry minimum and is adequate for most designs. Three is
used at high clock rates, where a single clock period is short compared with
the resolution time constant, and where the reliability target is high.

.. important::

   This block is correct **only** for signals whose bits are mutually
   independent: a level-encoded status flag, or a set of unrelated interrupt
   lines.

   It must **not** be used to transfer a multi-bit value whose bits change
   together. Each bit resolves independently, so the destination domain can
   sample a combination that never existed at the source. A four-bit counter
   crossing from ``0111`` to ``1000`` can be observed as any of the sixteen
   values, because all four bits change at once.

   For multi-bit traffic use ``cdc_pulse_sync`` for a single event,
   ``cdc_handshake`` for a value transferred on request, ``fifo_async`` for a
   continuous stream, or Gray-code the value before crossing it through this
   block. Gray coding is safe precisely because adjacent codes differ in
   exactly one bit, so a partially resolved sample is always either the old
   value or the new one.

Block diagram
=============

.. code-block:: text

                 domain boundary
                        |
                        |    +-----+     +-----+           +-----+
    d_async [WIDTH] ====|===>| D Q |====>| D Q |== ... ===>| D Q |===> q_sync
                        |    |     |     |     |           |     |     [WIDTH]
                        |    | FF0 |     | FF1 |           |FFn-1|
                        |    +--^--+     +--^--+           +--^--+
                        |       |           |                 |
    clk  ---------------|-------+-----------+--------- ... ---+
    rst_n --------------|-------+-----------+--------- ... ---+
                        |
                     may go        resolution time      guaranteed
                   metastable      = 1 clock period      stable

    STAGES flip-flops in total. Only the last stage is exported: nothing in
    the design may read an intermediate stage, because those can be metastable.

Timing diagram
==============

``STAGES = 3``. ``d_async`` changes asynchronously; the change appears at
``q_sync`` three destination clock edges later. The first sample after the
change may be metastable, which is shown as ``X``:

.. code-block:: text

              .    .    .    .    .    .    .    .
   clk     __/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__/‾\__
              .    .    .    .    .    .    .    .
   d_async ______/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
              .    .    .    .    .    .    .    .
   stage 0 __________/XXX\_/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾   may be metastable
              .    .    .    .    .    .    .    .
   stage 1 _______________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾   resolved
              .    .    .    .    .    .    .    .
   q_sync  ____________________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾   stable, safe to use

The latency is exactly ``STAGES`` destination clock cycles once the input has
been captured. Because the input is asynchronous, the *total* delay from the
source-domain change is between ``STAGES`` and ``STAGES + 1`` destination
clock periods depending on where the change lands relative to the edge.

Pulse width requirement
-----------------------

A level change must be held long enough to be sampled. A pulse narrower than
one destination clock period can be missed entirely. Where the source is
faster than the destination, use ``cdc_pulse_sync``, which converts the event
into a level toggle that cannot be missed.

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 18 20 12 14 36

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``WIDTH``
     - ``int unsigned``
     - 1
     - >= 1
     - Number of independent bits to synchronise. Each bit gets its own
       chain; the bits are never combined.
   * - ``STAGES``
     - ``int unsigned``
     - 2
     - >= 2
     - Length of the flip-flop chain. Latency and mean time between failures
       both rise with this value.
   * - ``RESET_VALUE``
     - ``logic [WIDTH-1:0]``
     - ``'0``
     - any
     - Value loaded into every stage while reset is asserted. Set it to the
       inactive level of the signal being crossed so that no spurious event is
       generated at reset release.

``STAGES < 2`` is rejected at elaboration with ``$fatal``: a single flip-flop
provides no metastability resolution time and is not a synchroniser.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 14 8 14 14 50

   * - Signal
     - Dir
     - Width
     - Domain
     - Description
   * - ``clk``
     - in
     - 1
     - dest
     - Destination-domain clock. The chain is clocked entirely from here.
   * - ``rst_n``
     - in
     - 1
     - async
     - Active-low reset, asserted asynchronously and released synchronously.
       Loads ``RESET_VALUE`` into every stage.
   * - ``d_async``
     - in
     - ``WIDTH``
     - **async**
     - Asynchronous input, sampled directly by the first flip-flop. No timing
       relationship to ``clk`` is assumed or required.
   * - ``q_sync``
     - out
     - ``WIDTH``
     - dest
     - Synchronised output, safe to use anywhere in the destination domain.

Usage examples
==============

Crossing a status flag
----------------------

.. code-block:: systemverilog

   cdc_sync_2ff #(
     .WIDTH  (1),
     .STAGES (3)
   ) u_sync_busy (
     .clk     (clk_cpu),
     .rst_n   (rst_n_cpu),
     .d_async (busy_from_periph),
     .q_sync  (busy_seen_by_cpu)
   );

Crossing a Gray-coded counter
-----------------------------

This is the safe way to move a multi-bit value continuously across a domain
boundary, and is exactly what ``fifo_async`` does internally with its
read and write pointers:

.. code-block:: systemverilog

   // Source domain: maintain the counter in Gray code.
   always_ff @(posedge clk_src or negedge rst_n_src) begin
     if (!rst_n_src) gray_q <= '0;
     else            gray_q <= (bin_q >> 1) ^ bin_q;
   end

   cdc_sync_2ff #(
     .WIDTH  (PTR_WIDTH),
     .STAGES (2)
   ) u_sync_ptr (
     .clk     (clk_dst),
     .rst_n   (rst_n_dst),
     .d_async (gray_q),
     .q_sync  (gray_in_dst)
   );

Crossing an active-low signal
-----------------------------

Set ``RESET_VALUE`` to the inactive level, otherwise the destination sees a
spurious assertion for ``STAGES`` cycles after reset release:

.. code-block:: systemverilog

   cdc_sync_2ff #(
     .WIDTH       (1),
     .STAGES      (2),
     .RESET_VALUE (1'b1)          // inactive level of an active-low signal
   ) u_sync_error_n (
     .clk     (clk_cpu),
     .rst_n   (rst_n_cpu),
     .d_async (error_n_from_phy),
     .q_sync  (error_n_seen_by_cpu)
   );

Integration notes
-----------------

* Drive ``d_async`` directly from a flip-flop output in the source domain. A
  combinational function of several source signals can glitch, and a glitch
  that lands on the sampling edge is indistinguishable from a real change.
* Never read an intermediate stage. Only ``q_sync`` is guaranteed stable.
* Apply ``scripts/cdc_sync_2ff.sdc``. Without the constraints, a retiming or
  register-merging optimisation can dismantle the chain, and the design will
  fail in hardware while passing simulation.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_cdc_sync_2ff.py``
     - Reset state and ``RESET_VALUE`` handling, exact propagation latency,
       randomised traffic against a shift-register reference model, worst-case
       every-cycle toggling, asynchronous reset asserted mid-traffic, and
       independence of the ``WIDTH`` bit lanes.
   * - ``tb/tb_cdc_sync_2ff.sv``
     - Portable self-checking smoke test covering the same behaviour without a
       Python dependency.
   * - ``formal/cdc_sync_2ff_formal.sv``
     - Proof with free-running clocks: the reset value at once on
       reset, changes only on rising edges, and the input on the output
       once it has been stable across STAGES edges, at two and three
       stages.

.. code-block:: bash

   ctest --test-dir build -R 'cdc_sync_2ff'
