//=============================================================================
// Module      : multiplier_formal
// Category    : arithmetic
// Description : Formal property wrapper for multiplier.
//
// Proves, for every input sequence from reset, that an unsigned and a
// signed 8 x 6 multiplier with two pipeline stages present, on every cycle,
// the exact product of the operands applied two cycles earlier - read as
// unsigned or two's complement - with out_valid equal to in_valid two
// cycles earlier; a reset empties the pipeline, so both outputs are zero
// for the first two cycles. The reference multiplies in a wider signed
// width than the product, so its own arithmetic cannot overflow.
//
// Covers reach the most negative times the most negative operand and the
// largest unsigned product on the output.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module multiplier_formal (
    input wire       clk,
    input wire       rst_n,
    input wire       in_valid,
    input wire [7:0] a,
    input wire [5:0] b
);

  localparam int unsigned AW = 8;
  localparam int unsigned BW = 6;
  localparam int unsigned PW = AW + BW;
  localparam int unsigned L  = 2;

  logic          v_u, v_s;
  logic [PW-1:0] p_u, p_s;

  multiplier #(.A_WIDTH(AW), .B_WIDTH(BW), .SIGNED(0), .LATENCY(L)) dut_u (
      .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .a(a), .b(b),
      .out_valid(v_u), .product(p_u));
  multiplier #(.A_WIDTH(AW), .B_WIDTH(BW), .SIGNED(1), .LATENCY(L)) dut_s (
      .clk(clk), .rst_n(rst_n), .in_valid(in_valid), .a(a), .b(b),
      .out_valid(v_s), .product(p_s));

  // The inputs, delayed as the pipeline delays them; reset to zero operands.
  logic [AW-1:0] a_q [L];
  logic [BW-1:0] b_q [L];
  logic          v_q [L];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < L; s++) begin
        a_q[s] <= '0;
        b_q[s] <= '0;
        v_q[s] <= 1'b0;
      end
    end else begin
      a_q[0] <= a;
      b_q[0] <= b;
      v_q[0] <= in_valid;
      for (int s = 1; s < L; s++) begin
        a_q[s] <= a_q[s-1];
        b_q[s] <= b_q[s-1];
        v_q[s] <= v_q[s-1];
      end
    end
  end

  logic signed [PW+1:0] ref_u, ref_s;
  assign ref_u = $signed({2'b00, PW'(a_q[L-1])}) * $signed({2'b00, PW'(b_q[L-1])});
  assign ref_s = (PW+2)'($signed(a_q[L-1])) * (PW+2)'($signed(b_q[L-1]));

  initial assume (!rst_n);

  always @(*) begin
    if (rst_n) begin
      assert (p_u == ref_u[PW-1:0]);
      assert (p_s == ref_s[PW-1:0]);
      assert (v_u == v_q[L-1] && v_s == v_q[L-1]);

      cover (v_s && p_s == PW'(128 * 32));
      cover (v_u && p_u == PW'(255 * 63));
    end
  end

endmodule

`default_nettype wire
