.. _ip-cdc_pulse_sync:

==============
cdc_pulse_sync
==============

Transfers a single-cycle pulse between clock domains of unrelated frequencies.

Functional description
======================

An event — a one-cycle strobe — cannot be carried across a clock domain
boundary by a plain synchroniser, and the failure mode depends on the clock
ratio:

* **Source faster than destination.** A one-cycle source pulse can begin and
  end entirely between two destination sampling edges. The destination never
  sees it. The event is lost.
* **Source slower than destination.** The same pulse is present across several
  destination edges and is sampled on each of them. One event arrives as a
  burst.

Neither failure is intermittent in the usual sense: it is fully determined by
where the pulse lands, so a design can work in the lab and fail in the field
when a clock is re-tuned.

The fix is to stop transferring a pulse and transfer a *level* instead. A level
change cannot be missed, because it is still there on the next edge whatever
the ratio, and it cannot be duplicated, because the destination reports only
the edge.

Sequence of operation
---------------------

#. An accepted source pulse toggles a flip-flop in the source domain. The
   information is now encoded as "the level changed", not "a pulse happened".
#. The toggle crosses to the destination through a ``cdc_sync_2ff`` chain.
#. The destination detects either edge of the synchronised toggle and emits
   exactly one destination-domain pulse.
#. The destination's own copy of the toggle is synchronised back to the source,
   which is how the source learns the event has been consumed.

Step 4 is what makes the block correct rather than merely usually correct.
The round trip takes several cycles in each domain. A second event accepted
inside that window would toggle the source flip-flop back to its previous
value; the destination would then see no edge at all, and **both** events would
disappear. ``src_busy`` exports that window, and the block ignores any pulse
presented while busy rather than losing an event silently.

Block diagram
=============

.. code-block:: text

     source domain (src_clk)      |      destination domain (dst_clk)
                                  |
                +--------+        |        +---------+     +--------+
   src_pulse -->| toggle |--------|------->| sync_2ff|---->| edge   |--> dst_pulse
      &         |  FF    | toggle | STAGES |  chain  |     | detect |
   !src_busy    +---^----+  level |        +---------+     +---+----+
                    |             |                            |
                    |             |                            v
                    |             |                       +---------+
                    |             |                       | dst     |
                    |             |                       | toggle  |
                    |             |                       |  FF     |
                    |             |                       +----+----+
                    |             |                            |
                +---+-----+       |        +---------+         |
   src_busy <---| compare |<------|--------| sync_2ff|<--------+
                | (XOR)   | ack   | STAGES |  chain  |
                +---------+ level |        +---------+
                                  |

   src_busy = src_toggle XOR acknowledged_toggle
            = "my toggle has not come back around yet"

Timing diagram
==============

Source 10 ns, destination 27 ns, ``STAGES = 2``. The source is faster, so the
naive approach would lose the pulse entirely:

.. code-block:: text

               .   .   .   .   .   .   .   .   .   .   .   .
   src_clk   _/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_
               .   .   .   .   .   .   .   .   .   .   .   .
   src_pulse ___/‾‾‾\_______________________________________
               .   .   .   .   .   .   .   .   .   .   .   .
   src_toggle ______/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾  level, not a pulse
               .   .   .   .   .   .   .   .   .   .   .   .
   src_busy  ______/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_______
               .   .   .   .   .   .   .   .   .   .   .   .
   dst_clk   __/‾‾‾‾‾‾‾\_______/‾‾‾‾‾‾‾\_______/‾‾‾‾‾‾‾\____
               .   .   .   .   .   .   .   .   .   .   .   .
   dst_sync  ________________________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾  after STAGES edges
               .   .   .   .   .   .   .   .   .   .   .   .
   dst_pulse ________________________/‾‾‾‾‾‾‾\______________  exactly one cycle

``src_busy`` falls once the destination's toggle has made the return trip, at
which point the next event may be presented.

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 16 20 12 14 38

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``STAGES``
     - ``int unsigned``
     - 2
     - >= 2
     - Depth of both synchroniser chains. Raising it increases the latency in
       each direction, and therefore the minimum interval between events.

``STAGES < 2`` is rejected at elaboration with ``$fatal``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 8 8 12 56

   * - Signal
     - Dir
     - Width
     - Domain
     - Description
   * - ``src_clk``
     - in
     - 1
     - src
     - Source clock. No relationship to ``dst_clk`` is assumed.
   * - ``src_rst_n``
     - in
     - 1
     - src
     - Source-domain reset, active low.
   * - ``src_pulse``
     - in
     - 1
     - src
     - One-cycle event request. Ignored, and flagged by an assertion, if
       presented while ``src_busy`` is high.
   * - ``src_busy``
     - out
     - 1
     - src
     - High from acceptance of an event until the destination has consumed it.
   * - ``dst_clk``
     - in
     - 1
     - dst
     - Destination clock.
   * - ``dst_rst_n``
     - in
     - 1
     - dst
     - Destination-domain reset, active low.
   * - ``dst_pulse``
     - out
     - 1
     - dst
     - Exactly one destination clock cycle wide, one per accepted event.

Usage examples
==============

Crossing an interrupt
---------------------

.. code-block:: systemverilog

   cdc_pulse_sync #(.STAGES(2)) u_irq_sync (
     .src_clk   (clk_periph),
     .src_rst_n (rst_n_periph),
     .src_pulse (irq_event),
     .src_busy  (irq_busy),
     .dst_clk   (clk_cpu),
     .dst_rst_n (rst_n_cpu),
     .dst_pulse (irq_to_cpu)
   );

Respecting the busy signal
--------------------------

.. code-block:: systemverilog

   // Correct: the event is only presented when the block can take it.
   always_ff @(posedge clk_periph or negedge rst_n_periph) begin
     if (!rst_n_periph) begin
       src_pulse <= 1'b0;
     end else begin
       src_pulse <= event_pending && !irq_busy;
     end
   end

If events can genuinely arrive faster than the round trip, buffer them in the
source domain — for example with a counter that is drained one event at a time
— or move to ``fifo_async``, which is designed for continuous traffic.

Integration notes
-----------------

* Both resets must be released before events are presented. The block is safe
  if one domain is reset alone, but the event in flight at that moment is lost.
* ``dst_pulse`` is a registered output, one cycle wide, safe to use directly as
  an enable in the destination domain.
* Apply ``scripts/cdc_pulse_sync.sdc`` so that both crossings are declared and
  the synchroniser chains are preserved.

Verification
============

Every functional test runs at three clock ratios, because a pulse synchroniser
that works at one ratio can silently drop or duplicate events at another.

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_cdc_pulse_sync.py``
     - Reset state; a single event; the ``src_busy`` handshake including the
       requirement that busy clears on its own; randomised events at random
       gaps; maximum-rate bursts of 100 events, which is the case that breaks a
       toggle synchroniser without an acknowledge path; and an event presented
       immediately after reset release. Ratios exercised: 23/7, 7/23 and
       10/10.7 ns.
   * - ``tb/tb_cdc_pulse_sync.sv``
     - Portable self-checking smoke test at 10 ns / 27 ns, including a
       continuous check that ``dst_pulse`` is never wider than one cycle.
   * - ``formal/cdc_pulse_sync_formal.sv``
     - Proof with free-running clocks and independent resets: one
       destination pulse per accepted source pulse, one cycle long, at most
       one event in flight, src_busy high while it is.

.. code-block:: bash

   ctest --test-dir build -R 'cdc_pulse_sync'
