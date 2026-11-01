.. _ip-multiplier:

==========
multiplier
==========

Parameterised pipelined multiplier, signed or unsigned, with a configurable
number of pipeline stages.

Functional description
======================

The block multiplies ``a`` by ``b`` and presents the full-width product
``LATENCY`` cycles later, together with a valid flag pipelined alongside it.
A new operand pair may be presented every cycle; there is no back-pressure and
the pipeline cannot stall.

The product itself is computed with the ``*`` operator rather than as a
hand-written partial-product array. That is deliberate. Every synthesiser
recognises ``*`` and maps it onto whatever the target does best — a DSP slice
on an FPGA, a Booth-encoded Wallace tree on an ASIC — and any hand-written
structure would be worse on at least one of those and would defeat the mapping
on all of them.

What the block adds around the operator is the part that is easy to get wrong,
and it is where the verification effort goes.

Signedness
----------

Both operands are widened to the full product width *before* multiplying:

.. code-block:: systemverilog

   assign a_ext = P_WIDTH'(signed'(a));
   assign b_ext = P_WIDTH'(signed'(b));
   assign product_comb = P_WIDTH'(a_ext * b_ext);

Doing it this way rather than relying on the operator's own width rules is
what makes the signed case correct. A signed multiply must sign extend both
operands, and SystemVerilog makes an expression unsigned if *any* of its
operands is unsigned — so a signed multiply written without explicit extension
silently produces a huge positive product whenever an operand is negative.

The failure is partial, which is what makes it expensive: three of the four
sign combinations still give the right answer, and only the ones involving a
negative operand are wrong. ``test_sign_combinations`` exists for exactly this.

Width
-----

The product is ``A_WIDTH + B_WIDTH`` bits, which is always wide enough. The
largest magnitude product of an *m*-bit and an *n*-bit value fits in *m+n*
bits in both the signed and the unsigned interpretation, so **no overflow is
possible and none is reported**. A caller that needs a narrower result
truncates or rounds it downstream, where the rounding rule is a decision
rather than an accident.

Pipelining
----------

``LATENCY`` registers are placed on the product, written as a plain shift of
the result rather than as hand-placed cuts inside the multiplication. Retiming
is the tool's job: given registers on the output and a retiming pass enabled,
synthesis distributes them through the partial-product tree far better than a
human can, and on an FPGA it pushes them into the DSP slice's own pipeline
registers where they cost nothing at all.

The shift register is written as a loop rather than as a concatenation,
because ``{valid_q[LATENCY-2:0], in_valid}`` would be ``valid_q[-1:0]`` at
``LATENCY = 1`` — a malformed slice that some tools accept and others reject.
The loop form elaborates correctly at every legal depth.

Block diagram
=============

.. code-block:: text

                +------------------------------------------------------+
   a  =========>| sign/zero extend to P_WIDTH ---+                     |
    [A]         |                                |                     |
                |                                v                     |
   b  =========>| sign/zero extend to P_WIDTH -> (*) --> product_comb  |
    [B]         |                                         [P]          |
                |                                          |           |
                |     +------------------------------------+           |
                |     v                                                |
                |  +-------+   +-------+         +-------+             |
                |  |stage 0|-->|stage 1|-- ... ->|stage   |===========>|==> product
                |  +-------+   +-------+         |LATENCY-1            |      [P]
                |                                +-------+             |
   in_valid --->|  +-------+   +-------+         +-------+             |
                |  |valid 0|-->|valid 1|-- ... ->|valid   |----------->|--> out_valid
                |  +-------+   +-------+         |LATENCY-1            |
                |                                +-------+             |
                +------------------------------------------------------+
                           ^                    ^
                           |                    |
                          clk                 rst_n

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 18 14 10 14 44

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``A_WIDTH``
     - ``int unsigned``
     - 16
     - >= 1
     - Width of the first operand.
   * - ``B_WIDTH``
     - ``int unsigned``
     - 16
     - >= 1
     - Width of the second operand. Need not equal ``A_WIDTH``.
   * - ``SIGNED``
     - ``int unsigned``
     - 0
     - 0 or 1
     - Interpret both operands as two's complement. Applies to both: a mixed
       signed/unsigned multiply is not supported, because the caller can get
       one by widening the unsigned operand by one bit.
   * - ``LATENCY``
     - ``int unsigned``
     - 1
     - >= 1
     - Pipeline registers on the output. Zero is rejected: a combinational
       multiplier needs no clock, so use the operator directly.

Illegal parameter values are rejected at elaboration with ``$fatal``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 16 10 20 54

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``
     - in
     - 1
     - Rising-edge clock for the whole block.
   * - ``rst_n``
     - in
     - 1
     - Active-low reset. Asserted asynchronously, released synchronously.
       Clears the product and valid pipelines.
   * - ``in_valid``
     - in
     - 1
     - The operands are valid this cycle. The block accepts them
       unconditionally; there is no ready signal.
   * - ``a``
     - in
     - ``A_WIDTH``
     - First operand.
   * - ``b``
     - in
     - ``B_WIDTH``
     - Second operand.
   * - ``out_valid``
     - out
     - 1
     - ``product`` is valid this cycle. Asserted exactly ``LATENCY`` cycles
       after the ``in_valid`` that produced it.
   * - ``product``
     - out
     - ``A_WIDTH + B_WIDTH``
     - The product. Never overflows.

Usage examples
==============

A filter tap
------------

.. code-block:: systemverilog

   multiplier #(
     .A_WIDTH (16),
     .B_WIDTH (16),
     .SIGNED  (1),
     .LATENCY (2)
   ) u_tap (
     .clk       (clk),
     .rst_n     (rst_n),
     .in_valid  (sample_valid),
     .a         (sample),
     .b         (coefficient),
     .out_valid (product_valid),
     .product   (product)
   );

A mixed signed/unsigned multiply
--------------------------------

Not supported directly, and it does not need to be: widen the unsigned
operand by one bit, which makes it a non-negative signed value, and use the
signed configuration.

.. code-block:: systemverilog

   multiplier #(
     .A_WIDTH (17),          // 16-bit unsigned, widened by one
     .B_WIDTH (16),
     .SIGNED  (1)
   ) u_mixed (
     .clk (clk), .rst_n (rst_n),
     .in_valid (valid),
     .a ({1'b0, unsigned_operand}),
     .b (signed_operand),
     .out_valid (product_valid),
     .product (product)
   );

Integration notes
-----------------

* There is no back-pressure. If the consumer can stall, put a FIFO or a skid
  buffer downstream — do not gate ``clk``.
* ``out_valid`` is the only correct way to know when a product is ready.
  Counting cycles in the caller works until ``LATENCY`` is changed, which is
  exactly the sort of change the parameter exists to make easy.
* Enable retiming in synthesis. The pipeline registers are deliberately all
  at the output; without retiming they do nothing for the critical path.
* On an FPGA, choose ``LATENCY`` to match the DSP slice's own pipeline depth
  (commonly 2 or 3 for a 16x16 at speed). Fewer stages leave the slice's
  registers unused; more add cost for nothing.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_multiplier.py``
     - The reset state; the latency, counted in clock edges rather than by
       waiting for ``out_valid``, so a pipeline one stage too long or too
       short fails rather than quietly shifting every result; the identities;
       the four sign combinations at the extremes; full-rate traffic; traffic
       with randomised gaps in ``in_valid``, which catches a pipeline that
       advances on every clock rather than on valid data; an exhaustive sweep
       at narrow widths; a mid-stream reset; and a 2000-pair sustained run.
   * - ``tb/tb_multiplier.sv``
     - Portable self-checking testbench driven from an in-order queue of
       expected products, which checks pipeline ordering and latency as well
       as arithmetic, with an exhaustive 8x8 sweep.

.. code-block:: bash

   ctest --test-dir build -R 'multiplier'

Timing
======

The block is timed by OpenSTA on its synthesised netlist at the clock period
in its ``add_ip()`` registration. The multiplier array is the critical path at
any width worth pipelining, so this is the block in the arithmetic category
where the reported slack actually constrains the configuration: if it fails,
the fix is more ``LATENCY`` and a retiming pass, not a narrower operand.

Note that the generic standard-cell library used for the portfolio's timing
analysis has no multiplier macro, so the mapped netlist is a gate-level array.
The numbers are therefore a vendor-independent comparison between
configurations rather than a prediction of what a DSP slice will do.
