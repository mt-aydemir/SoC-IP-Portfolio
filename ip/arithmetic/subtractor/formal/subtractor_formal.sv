//=============================================================================
// Module      : subtractor_formal
// Category    : arithmetic
// Description : Formal property wrapper for subtractor.
//
// An exhaustive equivalence check: for every pair of 16-bit operands and
// both borrow-ins, each of the four configurations is compared with the
// header's definition written as integer arithmetic on a wider difference
// d = a - b - borrow_in:
//
//   borrow_out  set when the unsigned difference is negative, in every
//               configuration
//   unsigned    overflow is the borrow; saturation clamps to zero
//   signed      overflow when d leaves [-2**15, 2**15 - 1]; saturation
//               clamps to the bound it crossed
//
// Covers reach a borrow, each signed overflow direction, and a saturated
// result in both saturating configurations.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module subtractor_formal (
    input wire [15:0] a,
    input wire [15:0] b,
    input wire        borrow_in
);

  localparam int unsigned W = 16;
  localparam logic signed [W+1:0] S_MAX = (18'sd1 <<< (W - 1)) - 18'sd1;
  localparam logic signed [W+1:0] S_MIN = -(18'sd1 <<< (W - 1));

  logic [W-1:0] diff [4];
  logic         bout [4];
  logic         ovf [4];

  for (genvar k = 0; k < 4; k++) begin : g_cfg
    subtractor #(.WIDTH(W), .SIGNED(k & 1), .SATURATE(k >> 1)) dut (
        .a(a), .b(b), .borrow_in(borrow_in),
        .difference(diff[k]), .borrow_out(bout[k]), .overflow(ovf[k]));
  end

  logic signed [W+1:0] u_true, s_true;
  logic                u_neg, s_ovf;

  assign u_true = $signed((W+2)'(a)) - $signed((W+2)'(b)) - $signed((W+2)'(borrow_in));
  assign s_true = (W+2)'($signed(a)) - (W+2)'($signed(b)) - $signed((W+2)'(borrow_in));
  assign u_neg  = u_true < 0;
  assign s_ovf  = s_true > S_MAX || s_true < S_MIN;

  always @(*) begin
    for (int k = 0; k < 4; k++) assert (bout[k] == u_neg);
    assert (ovf[0] == u_neg && diff[0] == u_true[W-1:0]);
    assert (ovf[1] == s_ovf && diff[1] == s_true[W-1:0]);
    assert (ovf[2] == u_neg);
    assert (diff[2] == (u_neg ? '0 : u_true[W-1:0]));
    assert (ovf[3] == s_ovf);
    assert (diff[3] == (s_true > S_MAX ? W'(S_MAX) : s_true < S_MIN ? W'(S_MIN)
                                                                    : s_true[W-1:0]));

    cover (u_neg && !s_ovf);
    cover (s_true > S_MAX);
    cover (s_true < S_MIN);
    cover (diff[2] == '0 && u_neg);
    cover (diff[3] == W'(S_MAX) && s_ovf);
  end

endmodule

`default_nettype wire
