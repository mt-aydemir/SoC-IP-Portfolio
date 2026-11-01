//=============================================================================
// Module      : barrel_shifter_formal
// Category    : arithmetic
// Description : Formal property wrapper for barrel_shifter.
//
// An exhaustive equivalence check at two widths: 16, a power of two, and
// 12, where the amount field can express amounts of 12 to 15. For every
// data word, amount and operation, the output equals a reference that
// moves one bit at a time:
//
//   bit i of a left shift by n is in[i-n], or 0 below n
//   bit i of a right shift is in[i+n], or 0 (logical) or the sign bit
//   (arithmetic) above WIDTH-1-n
//   bit i of a rotate is in[(i -+ n) mod WIDTH]
//   operations 5 to 7 pass the data through
//
// Covers reach an out-of-range amount at width 12 for a shift and for a
// rotate.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module barrel_shifter_formal (
    input wire [15:0] data16,
    input wire [3:0]  amount16,
    input wire [11:0] data12,
    input wire [3:0]  amount12,
    input wire [2:0]  operation
);

  logic [15:0] out16, ref16;
  logic [11:0] out12, ref12;

  barrel_shifter #(.WIDTH(16)) dut16 (
      .data_in(data16), .amount(amount16), .operation(operation), .data_out(out16));
  barrel_shifter #(.WIDTH(12)) dut12 (
      .data_in(data12), .amount(amount12), .operation(operation), .data_out(out12));

  always @(*) begin
    for (int i = 0; i < 16; i++) begin
      unique case (operation)
        3'd0:    ref16[i] = (i >= amount16) ? data16[i - amount16] : 1'b0;
        3'd1:    ref16[i] = (i + amount16 < 16) ? data16[i + amount16] : 1'b0;
        3'd2:    ref16[i] = (i + amount16 < 16) ? data16[i + amount16] : data16[15];
        3'd3:    ref16[i] = data16[(i + 16 - amount16) % 16];
        3'd4:    ref16[i] = data16[(i + amount16) % 16];
        default: ref16[i] = data16[i];
      endcase
    end
    for (int i = 0; i < 12; i++) begin
      unique case (operation)
        3'd0:    ref12[i] = (i >= amount12) ? data12[i - amount12] : 1'b0;
        3'd1:    ref12[i] = (i + amount12 < 12) ? data12[i + amount12] : 1'b0;
        3'd2:    ref12[i] = (i + amount12 < 12) ? data12[i + amount12] : data12[11];
        3'd3:    ref12[i] = data12[(i + 24 - amount12) % 12];
        3'd4:    ref12[i] = data12[(i + amount12) % 12];
        default: ref12[i] = data12[i];
      endcase
    end
  end

  always @(*) begin
    assert (out16 == ref16);
    assert (out12 == ref12);

    cover (operation == 3'd2 && amount12 >= 4'd12 && data12[11] && out12 == 12'hFFF);
    cover (operation == 3'd3 && amount12 >= 4'd12 && out12 != data12);
  end

endmodule

`default_nettype wire
