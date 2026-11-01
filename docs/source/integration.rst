=================
Integration Guide
=================

This page covers what an integrator needs to know that is not specific to any
one block: how to pull the RTL into another project, how the reset and clocking
conventions fit together, and the rules that keep a multi-clock design correct.

Using the RTL in another project
================================

The RTL has no dependency on this repository's build system. A block is
self-contained apart from the IPs named in the ``DEPENDS`` field of its
``CMakeLists.txt``, and those dependencies are ordinary SystemVerilog files.

To pull a block into an FPGA or ASIC project, add its ``rtl/*.sv`` files and
those of its dependencies to the project's file list, dependencies first. For
example, ``fifo_async`` needs::

   ip/cdc/sync_2ff/rtl/cdc_sync_2ff.sv
   ip/memory/fifo_async/rtl/fifo_async.sv

Nothing in ``tb/``, ``cocotb/`` or ``scripts/`` is required for synthesis.

Reset convention
================

Every block uses an **active-low reset, asserted asynchronously and released
synchronously**. This combination is chosen deliberately:

* Asynchronous assertion means the design reaches a known state even if the
  clock is not yet running, which matters during power-up and during clock
  reconfiguration.
* Synchronous release means no flop ever sees its reset released within its own
  recovery/removal window, which is what prevents a metastable start-up.

The synchronous release is produced by ``cdc_reset_sync``, instantiated once
per clock domain at the top level of the integrating design:

.. code-block:: systemverilog

   cdc_reset_sync #(.STAGES(3)) u_rst_sync_core (
     .clk        (clk_core),
     .arst_n_in  (por_n),        // raw, asynchronous power-on reset
     .rst_n_out  (rst_n_core)    // distributed to the core clock domain
   );

Feed ``rst_n_core`` to every block in that domain. Do not distribute the raw
asynchronous reset directly: it is asynchronous to every domain, so its release
edge would violate recovery timing somewhere.

Clock domain crossing rules
===========================

The CDC blocks exist because ad-hoc crossings are the most common source of
silicon bugs that simulation does not catch. The rules:

**A single asynchronous bit** crosses through ``cdc_sync_2ff``. This is correct
only for signals whose bits are mutually independent — a status flag, a set of
unrelated interrupt lines.

**A multi-bit value must never cross through a bank of synchronisers.** Each bit
resolves independently, so the destination can sample a combination that never
existed at the source. Use instead:

.. list-table::
   :header-rows: 1
   :widths: 34 66

   * - Traffic
     - Block
   * - A single event or pulse
     - ``cdc_pulse_sync``
   * - A value transferred on request
     - ``cdc_handshake``
   * - A continuous data stream
     - ``fifo_async``
   * - A free-running counter
     - Gray-code it, then cross with ``cdc_sync_2ff``

**Constrain the crossings.** Synchroniser chains must not be retimed, merged or
spread across the die. Each CDC block's ``scripts/`` directory contains the
constraints to apply; the crossings are false paths for setup and hold, with a
maximum-delay constraint on the source-to-first-flop segment so that skew stays
below one destination clock period.

Streaming interface convention
==============================

Blocks that move data use a ready/valid pair, matching AXI4-Stream semantics:

* A transfer occurs on any rising clock edge where ``valid`` and ``ready`` are
  both high.
* Once ``valid`` is asserted it must remain asserted, with stable payload,
  until the transfer completes.
* ``ready`` may be asserted and withdrawn freely, and may depend
  combinationally on ``valid`` only where the block's documentation says so.

Both directions of that contract are checked by concurrent assertions inside
the blocks, so a protocol violation by the surrounding logic is reported in the
integrator's own simulation.

Memory inference
================

Memory blocks are written as inferable arrays, without vendor primitives or
``ram_style`` attributes. Synthesis tools map them onto block RAM, distributed
RAM or an ASIC macro according to their own heuristics, which is what makes the
same source portable across targets.

Where a specific implementation is required, guide the tool from the project's
constraints file rather than editing the IP. Adding a vendor attribute to the
RTL would break the portability the library is built on, and is rejected by the
style check.

Timing constraints
==================

Each block documents the clock period it is verified at, and its
``scripts/`` directory contains an SDC fragment with the constraints it needs:
clock definitions, false paths across CDC boundaries and any multi-cycle paths
its architecture relies on. Multi-cycle paths in particular are not optional —
a block that assumes one will fail timing or, worse, pass timing while being
functionally wrong if the constraint is omitted.

Parameter legality
==================

Every block validates its parameters at elaboration and calls ``$fatal`` on an
illegal combination, so a bad configuration fails immediately with a readable
message. The legal range of each parameter is documented in the block's
parameter table; values outside it are not supported even where they happen to
elaborate.
