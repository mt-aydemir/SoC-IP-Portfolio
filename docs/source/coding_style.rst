============
Coding Style
============

Consistency is what makes fifty separate blocks feel like one library. These
rules are enforced mechanically by ``tests/test_rtl_style.py``, which runs as
part of the regression, so a violation fails the build rather than a review.

Language
========

SystemVerilog-2017 (IEEE 1800-2017), restricted to the synthesisable subset in
``rtl/``. Simulation-only constructs are permitted in ``tb/`` and inside
``\`ifndef SYNTHESIS`` guards.

File layout
===========

One module per file, and the module name must equal the file name. This is the
rule that makes the source tree navigable without a database.

Every RTL file follows the same skeleton:

.. code-block:: systemverilog

   //=============================================================================
   // Module      : <name>
   // Category    : <category>
   // Description : <one paragraph, then the detail an integrator needs>
   //
   // Parameters
   //   <NAME>  <meaning, legal range>
   //
   // Latency     : <cycles>
   // Throughput  : <transfers per cycle>
   // Reset       : <polarity, synchronous or asynchronous>
   //
   // Copyright (c) 2026 SoC IP Portfolio Contributors
   // SPDX-License-Identifier: Apache-2.0
   //=============================================================================
   `default_nettype none

   module <name> #(...) (...);
     ...
   endmodule

   `default_nettype wire

``\`default_nettype none`` is mandatory. It turns a mistyped signal name from a
silently created one-bit wire into a compile error, which is the single most
valuable safety net available in Verilog.

Restoring ``\`default_nettype wire`` at the end of the file is equally
mandatory: the directive is global to the compilation unit, so a file that does
not restore it changes the meaning of every file compiled after it.

Naming
======

.. list-table::
   :header-rows: 1
   :widths: 30 30 40

   * - Object
     - Convention
     - Example
   * - Module
     - ``lower_snake_case``, category prefix where it disambiguates
     - ``cdc_async_fifo``
   * - Parameter
     - ``UPPER_SNAKE_CASE``
     - ``DATA_WIDTH``
   * - Localparam
     - ``UPPER_SNAKE_CASE``
     - ``PTR_WIDTH``
   * - Signal
     - ``lower_snake_case``
     - ``write_pointer``
   * - Registered signal
     - ``_q`` suffix where it clarifies
     - ``count_q``
   * - Active-low signal
     - ``_n`` suffix
     - ``rst_n``
   * - Input port
     - ``s_`` for sink, ``m_`` for source on streaming interfaces
     - ``s_valid``, ``m_ready``
   * - Generate block
     - ``g_`` prefix
     - ``g_per_lane``
   * - Assertion
     - ``a_`` prefix, property ``p_`` prefix
     - ``a_no_overflow``

Ports and types
===============

* Inputs are ``input wire``. Outputs driven from procedural code are
  ``output logic``.
* Widths are always parameterised. A literal width in a port declaration is a
  defect unless the width is genuinely fixed by a protocol.
* Use ``logic`` rather than ``reg``/``wire`` for internal signals.
* Use ``always_ff``, ``always_comb`` and ``always_latch`` — never bare
  ``always``. The intent-carrying forms let the tools check that the inferred
  hardware is what was meant.
* Use ``int unsigned`` for loop variables and non-negative parameters.
* **Boolean parameters are ``int unsigned``, not ``bit``**, with the convention
  ``0`` = off and ``1`` = on. A one-bit parameter overridden from a tool
  command line — ``verilator -GOUTPUT_REG=1``, which is exactly how ``PARAMS``
  reaches the flow — receives a 32-bit literal and emits a width-truncation
  warning on every build. Under the zero-warning lint policy that fails the
  IP, so the type is chosen to match how the parameter is actually driven.

Reset
=====

The portfolio default is an **active-low asynchronous reset with synchronous
release**:

.. code-block:: systemverilog

   always_ff @(posedge clk or negedge rst_n) begin
     if (!rst_n) begin
       count_q <= '0;
     end else begin
       count_q <= count_d;
     end
   end

Reset release is synchronised by ``cdc_reset_sync`` at the top of each clock
domain, which is what makes the asynchronous assertion safe. Blocks whose state
is naturally self-clearing, and large memory arrays where a reset would cost
significant area, deliberately have no reset; where that is the case the module
header says so explicitly.

Vendor independence
===================

No vendor primitive, macro or attribute may appear in ``rtl/``. Instantiating
``BUFG``, ``altsyncram``, ``SB_RAM40_4K`` or an ``(* ram_style = ... *)``
attribute is a hard error in the style test.

Memories, clock gates and clock multiplexers are written as inferable RTL. Any
competent synthesiser maps them onto the target technology, and the result is
portable across FPGA vendors and ASIC flows alike. Where a target genuinely
needs a primitive, the correct answer is a thin wrapper in the integrating
project, not a vendor dependency inside the IP.

Assertions
==========

Concurrent assertions document the contract and catch violations in the
integrator's testbench, not just in ours. They live inside ``\`ifndef
SYNTHESIS`` so no synthesis tool ever sees them:

.. code-block:: systemverilog

   `ifndef SYNTHESIS
     property p_no_overflow;
       @(posedge clk) disable iff (!rst_n) (write_en |-> !full);
     endproperty
     a_no_overflow : assert property (p_no_overflow)
       else $error("fifo_sync: write while full");
   `endif

Parameter legality is checked in an ``initial`` block with ``$fatal``, so an
illegal configuration fails loudly at elaboration rather than producing subtly
broken hardware.

Lint exceptions
===============

There are **no in-source lint waivers**. ``/* verilator lint_off ... */`` does
not appear anywhere in ``rtl/``, because a pragma buried in a source file is
invisible to anyone reading the flow and tends to outlive the reason it was
added.

Where a diagnostic genuinely cannot be avoided, the exception is declared in
that IP's ``CMakeLists.txt`` through ``LINT_ARGS``, next to a comment saying
why. That keeps it visible in the build description, scoped to one IP, and
easy to audit — ``grep LINT_ARGS ip/`` lists every exception in the portfolio.

The bar for adding one is that the construct is correct and the tool is
reporting a hazard the hardware handles. At present there is exactly one:

``ram_dp`` — ``-Wno-MULTIDRIVEN``
   A true dual-port memory is written from two clocked processes, one per
   port. That is the structure every synthesiser recognises as a dual-port
   macro, and it cannot be expressed any other way when the ports have
   independent clocks. Verilator correctly observes that the array has two
   driving blocks; the collision rules that result are documented in the
   block's header and are the integrator's responsibility, exactly as they
   are for the physical macro.

Mechanical rules
================

* Two-space indentation. Tab characters are an error.
* Maximum line length 100 columns.
* No ``TODO``, ``FIXME``, ``XXX``, ``HACK`` or ``PLACEHOLDER`` markers in
  released RTL. Unfinished work does not merge.
* Every file carries an ``SPDX-License-Identifier``.
* Comments explain *why*. What the code does should be evident from the code.
