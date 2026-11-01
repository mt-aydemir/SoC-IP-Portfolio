.. _ip-clk_mux:

=======
clk_mux
=======

Glitch-free multiplexer between two asynchronous clocks.

Functional description
======================

Switching clocks with a plain multiplexer produces a glitch whenever the select
changes while either clock is high. The output jumps from one clock's level to
the other's, which can create a pulse arbitrarily narrower than either source
period — down to a few picoseconds if the two edges nearly coincide:

.. code-block:: text

   clk0    __/‾‾\__/‾‾\__/‾‾\__/‾‾\__
   clk1    ____/‾‾‾‾‾\_____/‾‾‾‾‾\___
   select  ________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
   naive   __/‾‾\__/\/‾‾‾‾‾\_____/‾‾‾    runt

Downstream flip-flops then see an edge that violates their minimum pulse width.
The failure is silent and unreproducible.

This block makes the two clocks cooperate instead:

#. Each clock owns a synchroniser chain holding its own "I am selected" flag.
#. Each flag is qualified with the *other* clock's flag inverted, so at most
   one clock can be enabled at any instant. The dead time between one clock
   releasing and the other taking over is what removes the glitch.
#. The final stage of each chain is clocked on the **falling** edge, so the
   enable presented to its AND gate changes only while that clock is low — the
   same principle as ``clk_gate``.

The output is therefore a wired OR of two mutually exclusive gated clocks,
never a multiplexer between two live ones.

Withdrawing a request mid-changeover
------------------------------------

Each branch's chain is **cleared** when its request is withdrawn, not shifted.
A plain shift register would let a ``1`` that is already in flight continue to
the output after the request had gone, so a ``select`` that toggles during a
changeover could enable both branches at once — the exact glitch the block
exists to prevent. Clearing means an enable can only ever rise after ``STAGES``
*consecutive* cycles of a held request.

.. note::

   This was not a theoretical concern. The first implementation used a plain
   shift register and the block's own both-branches-enabled assertion caught it
   during bring-up, under a testbench that toggled ``select`` faster than the
   changeover could complete.

Usage rule
----------

.. important::

   ``select`` must be held stable until ``clk_active`` has followed it.

This is a requirement of every glitch-free clock multiplexer, including hard
macro cells, and it is why ``clk_active`` exists: it reports which clock is
actually driving the output, so the integrator never has to guess when the
changeover finished.

.. code-block:: systemverilog

   always_ff @(posedge clk_cfg or negedge rst_n_cfg) begin
     if (!rst_n_cfg)                select <= 1'b0;
     else if (select == clk_active) select <= requested_clock;
   end

Violating the rule is safe — the block will not glitch — but the switch is
simply delayed until ``select`` settles.

Stalled clocks
--------------

Both clocks must be running for a changeover to complete: the incoming branch
needs ``STAGES`` of its own clock edges to enable. If the incoming clock is
dead, the block never finishes the switch and holds the output low. That is the
safe failure: downstream logic stops rather than being clocked by a malformed
edge, and the switch completes on its own if the clock later starts.

Block diagram
=============

.. code-block:: text

    branch 0 (clk0 domain)
    +--------------------------------------------------+
    |  request0 = ~select & ~enable1                    |
    |      |                                            |
    |      v                                            |
    |  +---------------+      +----------------+        |
    |  | sel0_q chain  |----->| enable0        |        |
    |  | STAGES deep   |      | (negedge clk0) |----+   |
    |  | cleared when  |      +----------------+    |   |
    |  | request0 = 0  |                            |   |
    |  +---------------+                            |   |
    +-----------------------------------------------|---+
                                                    |
                                         clk0 --AND-+---+
                                                        |
                                                       OR ---> clk_out
                                                        |
                                         clk1 --AND-+---+
                                                    |
    branch 1 (clk1 domain)                          |
    +-----------------------------------------------|---+
    |  request1 = select & ~enable0                  |   |
    |      |                                         |   |
    |      v                                         |   |
    |  +---------------+      +----------------+     |   |
    |  | sel1_q chain  |----->| enable1        |-----+   |
    |  +---------------+      | (negedge clk1) |         |
    |                         +----------------+         |
    +----------------------------------------------------+

    clk_active = enable1

Timing diagram
==============

A switch from ``clk0`` to ``clk1``. Note the dead time in the middle, during
which the output is held low — that gap is the mechanism, not a defect:

.. code-block:: text

              .   .   .   .   .   .   .   .   .   .   .
   clk0     _/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_/‾\_
              .   .   .   .   .   .   .   .   .   .   .
   clk1     ___/‾‾‾‾‾\_____/‾‾‾‾‾\_____/‾‾‾‾‾\_____/‾‾‾‾‾
              .   .   .   .   .   .   .   .   .   .   .
   select   ____/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
              .   .   .   .   .   .   .   .   .   .   .
   enable0  ‾‾‾‾‾‾‾‾‾‾‾‾‾\______________________________
              .   .   .   .   .   .   .   .   .   .   .
   enable1  ____________________________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
              .   .   .   .   .   .   .   .   .   .   .
   clk_out  _/‾\_/‾\_/‾\_______________/‾‾‾‾‾\_____/‾‾‾‾‾
              .   .   .   .   .   .   .   .   .   .   .
              clk0 running |  dead time  | clk1 running
              .   .   .   .   .   .   .   .   .   .   .
   clk_active ‾‾‾‾‾‾‾‾‾‾ 0 ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾/‾‾‾‾ 1 ‾‾‾

Both enables fall before either rises. Every pulse on ``clk_out`` is a whole
pulse of whichever clock is enabled.

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
   * - ``STAGES``
     - ``int unsigned``
     - 2
     - >= 2
     - Synchroniser depth in each branch. Sets both the metastability margin
       and the changeover latency: a switch costs roughly ``STAGES`` cycles of
       the outgoing clock plus ``STAGES`` of the incoming one.

``STAGES < 2`` is rejected at elaboration with ``$fatal``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 8 8 68

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk0``
     - in
     - 1
     - Clock 0. Selected out of reset.
   * - ``clk1``
     - in
     - 1
     - Clock 1. No relationship to ``clk0`` is assumed.
   * - ``rst0_n``
     - in
     - 1
     - Reset for branch 0, active low, released synchronously to ``clk0``.
   * - ``rst1_n``
     - in
     - 1
     - Reset for branch 1, active low, released synchronously to ``clk1``.
   * - ``select``
     - in
     - 1
     - Requested clock. Asynchronous to both; each branch synchronises it
       locally, so no external synchroniser is needed.
   * - ``clk_active``
     - out
     - 1
     - Which clock is actually driving the output: 0 for ``clk0``, 1 for
       ``clk1``. Hold ``select`` stable until this matches it.
   * - ``clk_out``
     - out
     - 1
     - Selected clock. A generated clock: declare it in the SDC.

Usage examples
==============

Switching between a reference and a PLL output
----------------------------------------------

.. code-block:: systemverilog

   clk_mux #(.STAGES(2)) u_clk_sel (
     .clk0       (clk_ref),
     .clk1       (clk_pll),
     .rst0_n     (rst_n_ref),
     .rst1_n     (rst_n_pll),
     .select     (use_pll),
     .clk_active (pll_is_live),
     .clk_out    (clk_core)
   );

Only switch to the PLL once it has locked, and switch back to the reference
before reconfiguring it — the block will hold the output low if asked for a
clock that is not running, which stalls the core rather than corrupting it.

Driving select safely
---------------------

.. code-block:: systemverilog

   always_ff @(posedge clk_cfg or negedge rst_n_cfg) begin
     if (!rst_n_cfg) begin
       select <= 1'b0;
     end else if (select == clk_active) begin
       // The previous switch has landed; a new request may be issued.
       select <= pll_locked && want_high_speed;
     end
   end

Integration notes
-----------------

* ``clk_out`` is a generated clock derived from *both* sources. Declare both
  derivations and put the two source clocks in asynchronous clock groups; see
  ``scripts/clk_mux.sdc``.
* Each branch needs a reset released synchronously to its own clock. Use one
  ``cdc_reset_sync`` per branch.
* Downstream logic sees a clock that stops for the duration of the changeover.
  Anything with a real-time requirement — a UART mid-character, a DRAM refresh
  counter — must be quiesced before switching.
* For more than two clocks, cascade instances in a tree rather than widening
  the block. A cascade keeps the mutual-exclusion argument to two parties at
  each node, which is what makes it verifiable.

Verification
============

Every test runs with a phase monitor attached. The output is allowed to be
*slow* during the dead time, but never *fast*: any phase shorter than the
narrowest source phase is a runt.

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_clk_mux.py``
     - Reset selects ``clk0``; switching in both directions with the output
       rate confirmed against each source period; twenty back-to-back switches;
       randomised switching at asynchronous times; 200 deliberate violations of
       the usage rule, which must delay the switch but never glitch; and a
       stalled source clock, where the output must park low and ``clk_active``
       must not report a clock that is not running.
   * - ``tb/tb_clk_mux.sv``
     - Portable smoke test at 10 ns / 27 ns measuring every output phase.

.. code-block:: bash

   ctest --test-dir build -R 'clk_mux'
