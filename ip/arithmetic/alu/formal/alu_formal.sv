//=============================================================================
// Module      : alu_formal
// Category    : arithmetic
// Description : Formal property wrapper for alu.
//
// An exhaustive equivalence check at WIDTH = 16: for every pair of operands,
// every opcode and both carry-ins, the result and all four flags equal the
// header's definition written as integer arithmetic:
//
//   ADD   a + b + carry_in; C is the carry out of the top bit, V the signed
//         sum leaving [-2**15, 2**15 - 1]
//   SUB   a - b - !carry_in; C is set when no borrow occurred (ARM/x86),
//         V the signed difference leaving the range
//   logic, NOT, PASS, PASSB as their operators; shifts and rotates by
//   b[3:0]; SLT and SLTU the signed and unsigned a < b as 0 or 1;
//   opcode 4'hF gives zero
//   Z and N from the result for every opcode; C and V zero unless the
//   opcode is ADD or SUB
//
// Covers reach a carry, a borrow, both overflow directions and an SLT that
// disagrees with SLTU.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module alu_formal (
    input wire [15:0] a,
    input wire [15:0] b,
    input wire [3:0]  opcode,
    input wire        carry_in
);

  localparam int unsigned W = 16;
  localparam logic signed [W+1:0] S_MAX = (18'sd1 <<< (W - 1)) - 18'sd1;
  localparam logic signed [W+1:0] S_MIN = -(18'sd1 <<< (W - 1));

  logic [W-1:0] result;
  logic         z, n, c, v;

  alu #(.WIDTH(W)) dut (
      .a(a), .b(b), .opcode(opcode), .carry_in(carry_in),
      .result(result), .flag_zero(z), .flag_negative(n), .flag_carry(c),
      .flag_overflow(v));

  logic        [W:0]   add_u;
  logic signed [W+1:0] add_s, sub_s;
  logic                sub_borrow;
  logic signed [W-1:0] sa, sb;
  logic [3:0]          sh;
  logic [W-1:0]        want;
  logic                want_c, want_v;

  assign sa         = a;
  assign sb         = b;
  assign sh         = b[3:0];
  assign add_u      = (W+1)'(a) + (W+1)'(b) + (W+1)'(carry_in);
  assign add_s      = (W+2)'(sa) + (W+2)'(sb) + (W+2)'(carry_in);
  assign sub_s      = (W+2)'(sa) - (W+2)'(sb) - (W+2)'(!carry_in);
  assign sub_borrow = (W+1)'(a) < (W+1)'(b) + (W+1)'(!carry_in);

  always @(*) begin
    want_c = 1'b0;
    want_v = 1'b0;
    unique case (opcode)
      4'h0: begin
        want   = add_u[W-1:0];
        want_c = add_u[W];
        want_v = add_s > S_MAX || add_s < S_MIN;
      end
      4'h1: begin
        want   = sub_s[W-1:0];
        want_c = !sub_borrow;
        want_v = sub_s > S_MAX || sub_s < S_MIN;
      end
      4'h2:    want = a & b;
      4'h3:    want = a | b;
      4'h4:    want = a ^ b;
      4'h5:    want = ~a;
      4'h6:    want = a << sh;
      4'h7:    want = a >> sh;
      4'h8:    want = W'(sa >>> sh);
      4'h9:    want = (a << sh) | (a >> (5'd16 - 5'(sh)));
      4'hA:    want = (a >> sh) | (a << (5'd16 - 5'(sh)));
      4'hB:    want = W'(sa < sb);
      4'hC:    want = W'(a < b);
      4'hD:    want = a;
      4'hE:    want = b;
      default: want = '0;
    endcase
  end

  always @(*) begin
    assert (result == want);
    assert (z == (want == '0));
    assert (n == want[W-1]);
    assert (c == want_c);
    assert (v == want_v);

    cover (opcode == 4'h0 && c);
    cover (opcode == 4'h1 && !c);
    cover (opcode == 4'h0 && v && !n);
    cover (opcode == 4'h1 && v && n);
    cover (opcode == 4'hB && result == 16'd1 && !(a < b));
  end

endmodule

`default_nettype wire
