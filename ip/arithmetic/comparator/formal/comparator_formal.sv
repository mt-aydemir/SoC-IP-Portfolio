//=============================================================================
// Module      : comparator_formal
// Category    : arithmetic
// Description : Formal property wrapper for comparator.
//
// An exhaustive equivalence check: for every pair of 16-bit operands, the
// six outputs of the unsigned and the signed comparator equal the
// corresponding relational operators on the operands read as unsigned and
// as two's complement numbers. Covers reach a pair on which the two
// interpretations disagree, in each order, and equality.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module comparator_formal (
    input wire [15:0] a,
    input wire [15:0] b
);

  localparam int unsigned W = 16;

  logic [5:0] flags [2];     // eq, ne, lt, le, gt, ge

  for (genvar k = 0; k < 2; k++) begin : g_cfg
    comparator #(.WIDTH(W), .SIGNED(k)) dut (
        .a(a), .b(b),
        .equal(flags[k][5]), .not_equal(flags[k][4]), .less(flags[k][3]),
        .less_equal(flags[k][2]), .greater(flags[k][1]), .greater_equal(flags[k][0]));
  end

  logic signed [W-1:0] sa, sb;
  assign sa = a;
  assign sb = b;

  always @(*) begin
    assert (flags[0] == {a == b, a != b, a < b, a <= b, a > b, a >= b});
    assert (flags[1] == {sa == sb, sa != sb, sa < sb, sa <= sb, sa > sb, sa >= sb});

    cover (a < b && sa > sb);
    cover (a > b && sa < sb);
    cover (a == b);
  end

endmodule

`default_nettype wire
