//=============================================================================
// Module      : adder_formal
// Category    : arithmetic
// Description : Formal property wrapper for adder.
//
// An exhaustive equivalence check: for every pair of 16-bit operands and
// both carry-ins, each of the four configurations - signed or unsigned,
// saturating or wrapping - is compared with the header's definition written
// as integer arithmetic on a wider sum:
//
//   unsigned  overflow when a + b + cin exceeds 2**16 - 1; saturates to
//             all-ones
//   signed    overflow when the true sum leaves [-2**15, 2**15 - 1];
//             saturates to the bound it crossed
//   carry_out is the carry out of the top bit in every configuration
//
// Covers reach an overflow in each direction and a saturated result in
// every configuration.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module adder_formal (
    input wire [15:0] a,
    input wire [15:0] b,
    input wire        carry_in
);

  localparam int unsigned W = 16;
  localparam logic signed [W+1:0] S_MAX = (18'sd1 <<< (W - 1)) - 18'sd1;
  localparam logic signed [W+1:0] S_MIN = -(18'sd1 <<< (W - 1));

  logic [W-1:0] sum [4];
  logic         cout [4];
  logic         ovf [4];

  for (genvar k = 0; k < 4; k++) begin : g_cfg
    adder #(.WIDTH(W), .SIGNED(k & 1), .SATURATE(k >> 1)) dut (
        .a(a), .b(b), .carry_in(carry_in),
        .sum(sum[k]), .carry_out(cout[k]), .overflow(ovf[k]));
  end

  // Reference arithmetic, two bits wider than the operands.
  logic        [W+1:0] u_true;
  logic signed [W+1:0] s_true;
  logic                u_ovf, s_ovf;

  assign u_true = (W+2)'(a) + (W+2)'(b) + (W+2)'(carry_in);
  assign s_true = (W+2)'($signed(a)) + (W+2)'($signed(b)) + (W+2)'(carry_in);
  assign u_ovf  = u_true > (W+2)'((1 << W) - 1);
  assign s_ovf  = s_true > S_MAX || s_true < S_MIN;

  always @(*) begin
    for (int k = 0; k < 4; k++) assert (cout[k] == u_true[W]);
    // unsigned wrapping, signed wrapping
    assert (ovf[0] == u_ovf && sum[0] == u_true[W-1:0]);
    assert (ovf[1] == s_ovf && sum[1] == s_true[W-1:0]);
    // unsigned saturating
    assert (ovf[2] == u_ovf);
    assert (sum[2] == (u_ovf ? {W{1'b1}} : u_true[W-1:0]));
    // signed saturating
    assert (ovf[3] == s_ovf);
    assert (sum[3] == (s_true > S_MAX ? W'(S_MAX) : s_true < S_MIN ? W'(S_MIN)
                                                                   : s_true[W-1:0]));

    cover (u_ovf && !s_ovf);
    cover (s_true > S_MAX);
    cover (s_true < S_MIN);
    cover (sum[3] == W'(S_MIN) && s_ovf);
    cover (sum[2] == {W{1'b1}} && u_ovf);
  end

endmodule

`default_nettype wire
