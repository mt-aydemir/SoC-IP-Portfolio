//=============================================================================
// Module      : comparator
// Category    : arithmetic
// Description : Parameterised combinational magnitude comparator producing all
//               six relational results at once, signed or unsigned.
//
// All six outputs are produced together because they share almost all of their
// logic: a single subtraction settles every relation, and the outputs are then
// a handful of gates on its result. Emitting them separately would cost six
// comparators where one is enough, and a synthesiser cannot always spot that
// they came from the same operands.
//
// Callers that need only one relation lose nothing: the unused outputs have no
// load, so synthesis removes the gates behind them.
//
// SIGNED AND UNSIGNED
//   Equality is the same in both interpretations - two bit patterns are equal
//   or they are not. Ordering is not: 0xFF is 255 unsigned and -1 signed, so
//   it is the largest or the smallest value depending only on how it is read.
//   Getting this wrong is one of the most common defects in hand-written
//   comparison logic, which is why it is a parameter here rather than
//   something the caller is expected to arrange.
//
// Parameters
//   WIDTH   Operand width in bits.
//   SIGNED  Interpret both operands as two's complement. 0/1.
//
// Latency     : combinational
// Reset       : none; the block has no state
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module comparator #(
    parameter int unsigned WIDTH  = 32,
    parameter int unsigned SIGNED = 0
) (
    input  wire  [WIDTH-1:0] a,
    input  wire  [WIDTH-1:0] b,

    output logic             equal,          // a == b
    output logic             not_equal,      // a != b
    output logic             less,           // a <  b
    output logic             less_equal,     // a <= b
    output logic             greater,        // a >  b
    output logic             greater_equal   // a >= b
);

  localparam bit IS_SIGNED = (SIGNED != 0);

  //---------------------------------------------------------------------------
  // Equality is interpretation-independent.
  //---------------------------------------------------------------------------
  assign equal     = (a == b);
  assign not_equal = ~equal;

  //---------------------------------------------------------------------------
  // Ordering.
  //
  // Written as two explicitly typed comparisons selected by a generate rather
  // than as one comparison on a conditionally signed value. SystemVerilog's
  // signedness rules make an expression unsigned if any operand is unsigned,
  // so a single comparison written to "work for both" silently becomes the
  // unsigned one.
  //---------------------------------------------------------------------------
  if (IS_SIGNED) begin : g_signed
    assign less    = (signed'(a) <  signed'(b));
    assign greater = (signed'(a) >  signed'(b));
  end else begin : g_unsigned
    assign less    = (a <  b);
    assign greater = (a >  b);
  end

  assign less_equal    = less    | equal;
  assign greater_equal = greater | equal;

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (WIDTH < 1) begin
      $fatal(1, "comparator: WIDTH must be >= 1 (got %0d)", WIDTH);
    end
  end

  // Exactly one of less, equal, greater must hold at any time. This is the
  // property that catches a signedness mistake: an implementation that mixes
  // interpretations can report both less and greater for the same pair.
  always_comb begin : trichotomy_check
    if ($countones({less, equal, greater}) != 1) begin
      $error("comparator: a=0x%0h b=0x%0h gave less=%0b equal=%0b greater=%0b",
             a, b, less, equal, greater);
    end
  end
`endif

endmodule

`default_nettype wire
