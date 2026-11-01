//=============================================================================
// Module      : alu
// Category    : arithmetic
// Description : Combinational arithmetic and logic unit with condition flags.
//
// A datapath ALU: one operation per cycle selected by an opcode, with the four
// classical condition flags produced alongside the result.
//
// THE FLAGS
//   Z  zero      the result is all zeros
//   N  negative  the result's most significant bit, which is the sign under a
//                two's complement interpretation
//   C  carry     carry out of the top bit for an addition; for a subtraction
//                it is the *inverted* borrow, following the ARM and x86
//                convention rather than the 6502 one, so that "carry set"
//                means "no borrow"
//   V  overflow  the signed result was not representable
//
// Flag semantics are the part of an ALU most often got wrong, because they
// differ between architectures and the difference is invisible until a
// conditional branch behaves oddly. The conventions used here are stated
// explicitly above and checked in the testbench against a reference model.
//
//   C and V are only meaningful for the arithmetic operations. Logical, shift
//   and pass operations clear both rather than leaving stale values, so a
//   consumer never has to remember which opcode last wrote them.
//
// STRUCTURE
//   The adder and the shifter are instantiated rather than rewritten, so
//   there is one implementation of two's complement addition with overflow
//   detection in the portfolio, and one barrel shifter. The subtraction reuses
//   the same adder with the inverted operand, which is also how the hardware
//   does it.
//
// Parameters
//   WIDTH  Operand and result width in bits.
//
// Latency     : combinational
// Reset       : none; the block has no state
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module alu #(
    parameter int unsigned WIDTH = 32
) (
    input  wire  [WIDTH-1:0] a,
    input  wire  [WIDTH-1:0] b,
    input  wire  [3:0]       opcode,
    input  wire              carry_in,

    output logic [WIDTH-1:0] result,
    output logic             flag_zero,
    output logic             flag_negative,
    output logic             flag_carry,
    output logic             flag_overflow
);

  localparam int unsigned AMT_WIDTH = $clog2(WIDTH);

  localparam logic [3:0] OP_ADD  = 4'h0;   // a + b + carry_in
  localparam logic [3:0] OP_SUB  = 4'h1;   // a - b - !carry_in
  localparam logic [3:0] OP_AND  = 4'h2;
  localparam logic [3:0] OP_OR   = 4'h3;
  localparam logic [3:0] OP_XOR  = 4'h4;
  localparam logic [3:0] OP_NOT  = 4'h5;   // ~a
  localparam logic [3:0] OP_SLL  = 4'h6;   // a << b
  localparam logic [3:0] OP_SRL  = 4'h7;   // a >> b, logical
  localparam logic [3:0] OP_SRA  = 4'h8;   // a >> b, arithmetic
  localparam logic [3:0] OP_ROL  = 4'h9;
  localparam logic [3:0] OP_ROR  = 4'hA;
  localparam logic [3:0] OP_SLT  = 4'hB;   // signed   a < b -> 1
  localparam logic [3:0] OP_SLTU = 4'hC;   // unsigned a < b -> 1
  localparam logic [3:0] OP_PASS = 4'hD;   // a
  localparam logic [3:0] OP_PASSB= 4'hE;   // b

  //---------------------------------------------------------------------------
  // Shared adder. Subtraction inverts the second operand and the carry in,
  // which is the same identity subtractor uses.
  //---------------------------------------------------------------------------
  logic             is_subtract;
  logic [WIDTH-1:0] adder_b;
  logic             adder_carry_in;
  logic [WIDTH-1:0] adder_sum;
  logic             adder_carry_out;
  logic             adder_overflow;

  assign is_subtract    = (opcode == OP_SUB) ||
                          (opcode == OP_SLT) || (opcode == OP_SLTU);
  assign adder_b        = is_subtract ? ~b : b;

  // ADD and SUB both chain through carry_in, so multi-word arithmetic works
  // in either direction: SUB computes a + ~b + carry_in, which is
  // a - b - !carry_in with carry_in read as "no borrow". The comparisons are
  // a plain a - b whatever carry_in holds, so they force it high.
  assign adder_carry_in = ((opcode == OP_SLT) || (opcode == OP_SLTU)) ? 1'b1
                                                                     : carry_in;

  // SIGNED is fixed at 1 so the adder always reports signed overflow on V;
  // the unsigned carry is taken from carry_out, which is interpretation
  // independent.
  adder #(
      .WIDTH    (WIDTH),
      .SIGNED   (1),
      .SATURATE (0)
  ) u_adder (
      .a         (a),
      .b         (adder_b),
      .carry_in  (adder_carry_in),
      .sum       (adder_sum),
      .carry_out (adder_carry_out),
      .overflow  (adder_overflow)
  );

  //---------------------------------------------------------------------------
  // Shared shifter
  //---------------------------------------------------------------------------
  logic [2:0]           shift_op;
  logic [WIDTH-1:0]     shift_result;

  always_comb begin
    unique case (opcode)
      OP_SRL:  shift_op = 3'd1;
      OP_SRA:  shift_op = 3'd2;
      OP_ROL:  shift_op = 3'd3;
      OP_ROR:  shift_op = 3'd4;
      default: shift_op = 3'd0;   // OP_SLL and every non-shift opcode
    endcase
  end

  barrel_shifter #(
      .WIDTH (WIDTH)
  ) u_shifter (
      .data_in   (a),
      .amount    (b[AMT_WIDTH-1:0]),
      .operation (shift_op),
      .data_out  (shift_result)
  );

  //---------------------------------------------------------------------------
  // Comparison results, derived from the shared subtraction.
  //
  // Signed less-than is "the sign of the difference, corrected for overflow":
  // when a subtraction overflows, the sign bit of the result is the opposite
  // of the true sign, so N XOR V is the reliable predicate. Unsigned
  // less-than is simply "a borrow occurred", which is the inverted carry.
  //---------------------------------------------------------------------------
  logic signed_less;
  logic unsigned_less;

  assign signed_less   = adder_sum[WIDTH-1] ^ adder_overflow;
  assign unsigned_less = ~adder_carry_out;

  //---------------------------------------------------------------------------
  // Result and flags
  //---------------------------------------------------------------------------
  logic arithmetic_op;

  assign arithmetic_op = (opcode == OP_ADD) || (opcode == OP_SUB);

  always_comb begin
    unique case (opcode)
      OP_ADD, OP_SUB: result = adder_sum;
      OP_AND:         result = a & b;
      OP_OR:          result = a | b;
      OP_XOR:         result = a ^ b;
      OP_NOT:         result = ~a;
      OP_SLL, OP_SRL, OP_SRA, OP_ROL, OP_ROR:
                      result = shift_result;
      OP_SLT:         result = WIDTH'(signed_less);
      OP_SLTU:        result = WIDTH'(unsigned_less);
      OP_PASS:        result = a;
      OP_PASSB:       result = b;
      default:        result = '0;
    endcase
  end

  assign flag_zero     = (result == '0);
  assign flag_negative = result[WIDTH-1];

  // Cleared for every non-arithmetic opcode so a consumer never reads a stale
  // carry or overflow left behind by an earlier operation.
  assign flag_carry    = arithmetic_op ? adder_carry_out : 1'b0;
  assign flag_overflow = arithmetic_op ? adder_overflow  : 1'b0;

  //---------------------------------------------------------------------------
  // Elaboration-time checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (WIDTH < 2) begin
      $fatal(1, "alu: WIDTH must be >= 2 (got %0d)", WIDTH);
    end
  end
`endif

endmodule

`default_nettype wire
