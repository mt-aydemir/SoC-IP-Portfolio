//=============================================================================
// Module      : adder
// Category    : arithmetic
// Description : Parameterised combinational adder with carry in and out,
//               signed and unsigned modes, and optional saturation.
//
// The block is deliberately combinational and has no clock. An adder is a
// leaf: where it needs to be registered, the register belongs to the pipeline
// stage that owns it, not to the adder. Building the register in would mean
// carrying a clock and a reset through every instantiation that does not want
// them, and would fix the retiming boundary in the wrong place.
//
// SIGNED AND UNSIGNED
//   The distinction changes nothing about the sum itself - two's complement
//   addition is bit-identical either way - but it changes completely what
//   counts as an overflow, and therefore what saturation does:
//
//     unsigned  overflow is carry out of the top bit
//               saturation clamps to all-ones
//     signed    overflow is the two operands sharing a sign that the result
//               does not; the carry out is meaningless
//               saturation clamps to the most positive or most negative value
//
// SATURATION
//   With SATURATE set, an overflowing result is clamped to the nearest
//   representable value instead of wrapping. That is what signal processing
//   wants: a filter that wraps turns a loud sample into a loud sample of the
//   opposite sign, which is audible as a click, while one that clamps merely
//   distorts. Control logic usually wants the opposite - a wrapping counter is
//   correct - so the default is off.
//
// Parameters
//   WIDTH     Operand and result width in bits.
//   SIGNED    Interpret the operands as two's complement. 0/1.
//   SATURATE  Clamp on overflow instead of wrapping. 0/1.
//
// Latency     : combinational
// Reset       : none; the block has no state
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module adder #(
    parameter int unsigned WIDTH    = 32,
    parameter int unsigned SIGNED   = 0,
    parameter int unsigned SATURATE = 0
) (
    input  wire  [WIDTH-1:0] a,
    input  wire  [WIDTH-1:0] b,
    input  wire              carry_in,

    output logic [WIDTH-1:0] sum,
    output logic             carry_out,
    output logic             overflow
);

  localparam bit IS_SIGNED   = (SIGNED   != 0);
  localparam bit DO_SATURATE = (SATURATE != 0);

  //---------------------------------------------------------------------------
  // The raw sum, one bit wider so the carry out falls out of the arithmetic
  // rather than having to be reconstructed from the operand sign bits.
  //---------------------------------------------------------------------------
  logic [WIDTH:0] wide_sum;

  assign wide_sum = {1'b0, a} + {1'b0, b} + (WIDTH+1)'(carry_in);

  assign carry_out = wide_sum[WIDTH];

  //---------------------------------------------------------------------------
  // Overflow.
  //
  // Unsigned: the carry out is the overflow, by definition.
  //
  // Signed: an overflow has occurred exactly when both operands have the same
  // sign and the result does not. Two numbers of opposite sign can never
  // overflow, which is why the condition is an AND of the two agreements
  // rather than a comparison against a limit.
  //---------------------------------------------------------------------------
  logic signed_overflow;

  assign signed_overflow = (a[WIDTH-1] == b[WIDTH-1]) &&
                           (wide_sum[WIDTH-1] != a[WIDTH-1]);

  assign overflow = IS_SIGNED ? signed_overflow : carry_out;

  //---------------------------------------------------------------------------
  // Saturation
  //---------------------------------------------------------------------------
  always_comb begin
    if (!DO_SATURATE || !overflow) begin
      sum = wide_sum[WIDTH-1:0];
    end else if (IS_SIGNED) begin
      // The sign of the operands tells us which limit was crossed: two
      // negatives can only underflow, two positives can only overflow.
      sum = a[WIDTH-1] ? {1'b1, {(WIDTH-1){1'b0}}}    // most negative
                       : {1'b0, {(WIDTH-1){1'b1}}};   // most positive
    end else begin
      sum = {WIDTH{1'b1}};
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (WIDTH < 2) begin
      $fatal(1, {"adder: WIDTH must be >= 2 (got %0d); a one-bit signed ",
                 "operand has no magnitude bits"}, WIDTH);
    end
  end
`endif

endmodule

`default_nettype wire
