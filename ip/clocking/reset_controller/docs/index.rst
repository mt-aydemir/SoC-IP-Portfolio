.. _ip-reset_controller:

================
reset_controller
================

Combines the reset sources of one clock domain and releases a staged reset tree
in a defined order.

Functional description
======================

A real SoC does not have one reset. It has a power-on reset, a software reset
written by the CPU, a watchdog timeout, and usually a debug reset. Those
sources have to be combined, stretched, synchronised and then released in an
order that matches the dependencies between blocks.

Order matters because the dependencies are real. A bus interconnect that starts
before its slaves will forward transactions into blocks that are still
resetting, and those transactions will never be answered — on AXI, a master
that never receives a response is stuck forever. A DMA engine that starts
before the interconnect issues reads that go nowhere. Releasing everything
simultaneously appears to work in simulation, where reset release is
instantaneous, and then fails intermittently in silicon.

The block provides four things:

**Source combining.** An asynchronous source and a synchronous request are
combined internally, so combinational glitches on the sources never reach the
reset tree.

**Minimum assertion time.** A software reset from a CPU write is one cycle
wide. One cycle is not enough: a block whose clock is gated, or which is in a
slower domain, can miss it entirely. The counter restarts whenever ``sw_reset``
is high, so the assertion always lasts at least ``MIN_ASSERT_CYCLES`` beyond
the last request, however short the request itself was.

**Synchronous release.** Delegated to ``cdc_reset_sync`` rather than
reimplemented, so there is one implementation of the asynchronous-assert /
synchronous-release structure in the portfolio and one place to get it right.

**Sequenced release.** ``NUM_STAGES`` outputs released in ascending index order
with ``STAGE_DELAY`` cycles between them.

Assign stage 0 to the most fundamental blocks — clocking, memory controllers —
and the highest stage to the masters that drive traffic.

On assertion, all stages assert together and immediately. Only the release is
sequenced. Bringing a system down in stages would leave transactions in flight
with no one left to answer them, which is exactly the failure the staged
release exists to prevent on the way up.

Block diagram
=============

.. code-block:: text

   arst_n_in --->+------------------+
                 | cdc_reset_sync   |---> core_rst_n
   clk --------->| SYNC_STAGES deep |          |
                 +------------------+          |
                                               v
   sw_reset --->+---------------------------------------+
                | counter                               |
                |   restarted while sw_reset is high    |
                |   counts to MIN_ASSERT_CYCLES         |
                |         + NUM_STAGES*STAGE_DELAY      |
                +----------------+----------------------+
                                 |
                                 | count_q
                                 v
                 +---------------------------------+
                 | per-stage comparators, each     |
                 | registered:                     |
                 |   rst_n_out[n] <=               |
                 |     count_q >= MIN_ASSERT +     |
                 |                n*STAGE_DELAY    |
                 +---------------------------------+
                          |    |    |    |
                          v    v    v    v
                    rst_n_out[0][1][2][3]     reset_active

Timing diagram
==============

``NUM_STAGES = 4``, ``STAGE_DELAY = 4``, ``MIN_ASSERT_CYCLES = 16``:

.. code-block:: text

   arst_n_in  ___________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾

   core_rst_n ______________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
                            |<-- SYNC_STAGES

   count_q    0 0 0 0 0 0 0 0 1 2 3 ... 16 17 18 19 20 ... 24 ... 28 ...

   rst_n_out[0] ______________________________/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾
                              |<-- MIN_ASSERT_CYCLES -->|

   rst_n_out[1] __________________________________________/‾‾‾‾‾‾‾‾‾‾‾‾
                                                |<- 4 ->|

   rst_n_out[2] ______________________________________________/‾‾‾‾‾‾‾‾
                                                        |<- 4 ->|

   rst_n_out[3] __________________________________________________/‾‾‾‾
                                                                |<- 4 ->|

   reset_active ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_____

A one-cycle software request, stretched:

.. code-block:: text

   sw_reset     ____/‾‾\______________________________________________

   rst_n_out[*] ‾‾‾‾‾\________________________________________/‾‾‾‾‾‾‾‾
                     ^ all stages assert immediately
                      |<--- at least MIN_ASSERT_CYCLES --->|

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 24 18 10 10 38

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``NUM_STAGES``
     - ``int unsigned``
     - 4
     - >= 1
     - Number of staged reset outputs.
   * - ``STAGE_DELAY``
     - ``int unsigned``
     - 4
     - >= 0
     - Clock cycles between consecutive stage releases. Zero releases every
       stage together, which is occasionally what is wanted.
   * - ``MIN_ASSERT_CYCLES``
     - ``int unsigned``
     - 16
     - >= 1
     - Minimum assertion time in clock cycles. Size it so that the slowest
       clock domain in the system sees at least a few of its own edges.
   * - ``SYNC_STAGES``
     - ``int unsigned``
     - 3
     - >= 2
     - Synchroniser depth applied to the release edge.

``NUM_STAGES``, ``MIN_ASSERT_CYCLES`` and ``SYNC_STAGES`` are all checked at
elaboration with ``$fatal``.

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
     - Clock of the domain this controller serves.
   * - ``arst_n_in``
     - in
     - 1
     - Asynchronous reset sources, active low. Combine the power-on reset and
       any external reset pin here, outside the block.
   * - ``sw_reset``
     - in
     - 1
     - Synchronous reset request, active high. A single-cycle pulse is enough.
   * - ``rst_n_out``
     - out
     - ``NUM_STAGES``
     - Staged resets, active low. Index 0 releases first.
   * - ``reset_active``
     - out
     - 1
     - High while any stage is still asserted. Useful as a CPU-readable status
       bit and as a qualifier for boot logic.

Usage examples
==============

A four-stage SoC reset tree
---------------------------

.. code-block:: systemverilog

   reset_controller #(
     .NUM_STAGES        (4),
     .STAGE_DELAY       (4),
     .MIN_ASSERT_CYCLES (16),
     .SYNC_STAGES       (3)
   ) u_rstctl (
     .clk          (clk_sys),
     .arst_n_in    (por_n & ~watchdog_timeout),
     .sw_reset     (cpu_soft_reset),
     .rst_n_out    ({rst_n_masters,   // [3] released last
                     rst_n_fabric,    // [2]
                     rst_n_slaves,    // [1]
                     rst_n_clocking}),// [0] released first
     .reset_active (system_in_reset)
   );

Note the bit order in the concatenation: ``rst_n_out[0]`` is the *last* element
written, and it is the one that releases first.

A single-stage controller
-------------------------

With ``NUM_STAGES = 1`` the block degenerates to a source combiner with a
minimum assertion time, which is still worth having over a bare synchroniser:

.. code-block:: systemverilog

   reset_controller #(
     .NUM_STAGES        (1),
     .MIN_ASSERT_CYCLES (32)
   ) u_periph_rst (
     .clk          (clk_periph),
     .arst_n_in    (por_n),
     .sw_reset     (periph_reset_request),
     .rst_n_out    (rst_n_periph),
     .reset_active ()
   );

Integration notes
-----------------

* One instance per clock domain. A reset synchronised to one clock is
  asynchronous to every other, so passing ``rst_n_out`` into another domain
  reintroduces the problem this block solves.
* Combine reset *sources* before the block, never combine its *outputs*.
  Combinational logic on a staged reset would put a glitch into a net the whole
  domain trusts.
* Size ``MIN_ASSERT_CYCLES`` from the slowest consumer, not from this domain's
  clock. A 16-cycle assertion at 100 MHz is 160 ns, which is less than two
  cycles of a 10 MHz peripheral.
* ``STAGE_DELAY`` must be long enough for a released block to become able to
  answer traffic, not merely to leave reset. Memory controllers in particular
  may need calibration time; where that is the case, gate the next stage on a
  ready signal instead of a fixed delay.

Verification
============

An order monitor runs for the whole regression, so a stage released out of turn
fails whichever test happens to be running.

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Suite
     - Contents
   * - ``cocotb/test_reset_controller.py``
     - Every stage asserted while the source is held; the staged release
       captured and checked for exact ``STAGE_DELAY`` spacing; a one-cycle
       software request stretched to at least ``MIN_ASSERT_CYCLES``;
       asynchronous assertion a third of the way through a clock period;
       fifteen randomised software resets of random width; and a repeatability
       check confirming that twelve consecutive resets each produce an
       identical release sequence — a counter that failed to clear would show
       up here.
   * - ``tb/tb_reset_controller.sv``
     - Portable smoke test with a continuous release-order monitor and
       measured stage spacing.

.. code-block:: bash

   ctest --test-dir build -R 'reset_controller'
