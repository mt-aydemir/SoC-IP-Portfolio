//=============================================================================
// Module      : subtractor
// Category    : arithmetic
// Description : Parameterised combinational subtractor with borrow in and out,
//               signed and unsigned modes, and optional saturation.
//
// The block instantiates `adder` rather than reimplementing a carry chain.
// Two's complement subtraction is addition of the inverted subtrahend with the
// carry in set:
//
//     a - b - borrow_in  ==  a + ~b + ~borrow_in
//
// The identity holds because ~b == -b - 1, so a + ~b + 1 == a - b. Adding
// ~borrow_in rather than 1 folds the incoming borrow in for free.
//
// Two things do NOT come for free from the adder and are handled here:
//
//   borrow_out   The adder produces a carry, and for subtraction a borrow is
//                its complement: no carry out means the subtraction went
//                below zero.
//
//   unsigned saturation
//                The adder clamps an unsigned overflow to all-ones, which is
//                the right limit for addition and the wrong one for
//                subtraction. An unsigned subtraction that goes negative must
//                clamp to zero, so saturation is applied here and the adder is
//                instantiated with it disabled.
//
//   unsigned overflow
//                The adder reports its unsigned overflow as the carry out,
//                which for a subtraction is inverted: a carry out means the
//                result did NOT go below zero. The unsigned overflow flag is
//                therefore the borrow, and is taken from borrow_out here
//                rather than from the adder.
//
// Signed overflow needs no special handling: the adder computes it as "both
// operands share a sign the result does not", and since ~b has the opposite
// sign bit to b, that expression evaluated on (a, ~b) is exactly the signed
// subtraction overflow condition.
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

module subtractor #(
    parameter int unsigned WIDTH    = 32,
    parameter int unsigned SIGNED   = 0,
    parameter int unsigned SATURATE = 0
) (
    input  wire  [WIDTH-1:0] a,
    input  wire  [WIDTH-1:0] b,
    input  wire              borrow_in,

    output logic [WIDTH-1:0] difference,
    output logic             borrow_out,
    output logic             overflow
);

  localparam bit IS_SIGNED   = (SIGNED   != 0);
  localparam bit DO_SATURATE = (SATURATE != 0);

  logic [WIDTH-1:0] raw_difference;
  logic             carry_out;
  logic             adder_overflow;

  //---------------------------------------------------------------------------
  // Saturation is disabled in the adder because its unsigned limit is wrong
  // for subtraction; it is applied below instead.
  //---------------------------------------------------------------------------
  adder #(
      .WIDTH    (WIDTH),
      .SIGNED   (SIGNED),
      .SATURATE (0)
  ) u_adder (
      .a         (a),
      .b         (~b),
      .carry_in  (~borrow_in),
      .sum       (raw_difference),
      .carry_out (carry_out),
      .overflow  (adder_overflow)
  );

  // No carry out of the top bit means the result went below zero.
  assign borrow_out = ~carry_out;

  // Signed: the adder's condition, evaluated on (a, ~b), is already the
  // signed subtraction overflow. Unsigned: the result is unrepresentable
  // exactly when it went below zero, which is the borrow.
  assign overflow = IS_SIGNED ? adder_overflow : borrow_out;

  //---------------------------------------------------------------------------
  // Saturation
  //---------------------------------------------------------------------------
  always_comb begin
    if (!DO_SATURATE) begin
      difference = raw_difference;
    end else if (IS_SIGNED) begin
      if (overflow) begin
        // a and ~b share a sign; that shared sign says which limit was
        // crossed. A negative a minus a positive b can only underflow.
        difference = a[WIDTH-1] ? {1'b1, {(WIDTH-1){1'b0}}}    // most negative
                                : {1'b0, {(WIDTH-1){1'b1}}};   // most positive
      end else begin
        difference = raw_difference;
      end
    end else begin
      // Unsigned: clamp to zero rather than to all-ones.
      difference = borrow_out ? '0 : raw_difference;
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (WIDTH < 2) begin
      $fatal(1, "subtractor: WIDTH must be >= 2 (got %0d)", WIDTH);
    end
  end
`endif

endmodule

`default_nettype wire
