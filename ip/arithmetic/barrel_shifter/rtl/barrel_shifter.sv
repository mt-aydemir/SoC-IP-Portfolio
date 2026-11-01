//=============================================================================
// Module      : barrel_shifter
// Category    : arithmetic
// Description : Combinational barrel shifter: logical and arithmetic shifts
//               and rotates, in either direction, by any amount in one cycle.
//
// A barrel shifter is a tree of multiplexer stages, one per bit of the shift
// amount: stage k either passes its input through or shifts it by 2**k. That
// structure is what makes the delay logarithmic in WIDTH rather than linear,
// and it is what `>>`, `<<` and `>>>` infer on every synthesiser worth using.
// The operators are therefore used directly - a hand-built mux tree would be
// larger, slower and harder to read, and would defeat any target that has a
// dedicated shifter.
//
// OPERATIONS
//   SHIFT_LEFT     zeros shifted in at the bottom
//   SHIFT_RIGHT    zeros shifted in at the top (logical)
//   ARITH_RIGHT    the sign bit replicated at the top
//   ROTATE_LEFT    bits leaving the top re-enter at the bottom
//   ROTATE_RIGHT   bits leaving the bottom re-enter at the top
//
// An arithmetic *left* shift is deliberately absent: it is identical to a
// logical left shift, and offering both would suggest a difference that does
// not exist.
//
// SHIFT AMOUNT
//   The amount is $clog2(WIDTH) bits wide, so every representable amount is in
//   range for a power-of-two WIDTH. For a non-power-of-two WIDTH the encoding
//   can express amounts of WIDTH or more; those are handled by producing the
//   fully shifted result (all zeros, or all sign bits) for shifts, and by
//   reducing modulo WIDTH for rotates, which is the only definition that keeps
//   a rotate reversible.
//
// Parameters
//   WIDTH  Data width in bits.
//
// Latency     : combinational
// Reset       : none; the block has no state
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module barrel_shifter #(
    parameter int unsigned WIDTH = 32
) (
    input  wire  [WIDTH-1:0]          data_in,
    input  wire  [$clog2(WIDTH)-1:0]  amount,

    // Operation select, encoded to match the OP_* localparams below.
    input  wire  [2:0]                operation,

    output logic [WIDTH-1:0]          data_out
);

  localparam int unsigned AMT_WIDTH = $clog2(WIDTH);

  localparam logic [2:0] OP_SHIFT_LEFT   = 3'd0;
  localparam logic [2:0] OP_SHIFT_RIGHT  = 3'd1;
  localparam logic [2:0] OP_ARITH_RIGHT  = 3'd2;
  localparam logic [2:0] OP_ROTATE_LEFT  = 3'd3;
  localparam logic [2:0] OP_ROTATE_RIGHT = 3'd4;

  //---------------------------------------------------------------------------
  // Rotate amount, reduced modulo WIDTH.
  //
  // Only meaningful when WIDTH is not a power of two; otherwise the amount is
  // already in range and the reduction is a no-op that synthesis removes.
  //---------------------------------------------------------------------------
  logic [AMT_WIDTH-1:0] rotate_amount;

  if (2 ** AMT_WIDTH == WIDTH) begin : g_power_of_two
    assign rotate_amount = amount;
  end else begin : g_arbitrary_width
    assign rotate_amount = (amount >= AMT_WIDTH'(WIDTH))
                         ? AMT_WIDTH'(amount - AMT_WIDTH'(WIDTH))
                         : amount;
  end

  //---------------------------------------------------------------------------
  // A rotate is the OR of the two halves of a double-width shift. Building it
  // that way rather than as a separate structure lets synthesis share the mux
  // tree with the plain shifts.
  //---------------------------------------------------------------------------
  logic [WIDTH-1:0] rotated_left;
  logic [WIDTH-1:0] rotated_right;

  always_comb begin
    if (rotate_amount == '0) begin
      rotated_left  = data_in;
      rotated_right = data_in;
    end else begin
      rotated_left  = (data_in << rotate_amount) |
                      (data_in >> (AMT_WIDTH'(WIDTH) - rotate_amount));
      rotated_right = (data_in >> rotate_amount) |
                      (data_in << (AMT_WIDTH'(WIDTH) - rotate_amount));
    end
  end

  //---------------------------------------------------------------------------
  // Operation select
  //---------------------------------------------------------------------------
  always_comb begin
    unique case (operation)
      OP_SHIFT_LEFT:   data_out = data_in << amount;
      OP_SHIFT_RIGHT:  data_out = data_in >> amount;
      OP_ARITH_RIGHT:  data_out = WIDTH'(signed'(data_in) >>> amount);
      OP_ROTATE_LEFT:  data_out = rotated_left;
      OP_ROTATE_RIGHT: data_out = rotated_right;
      default:         data_out = data_in;
    endcase
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (WIDTH < 2) begin
      $fatal(1, {"barrel_shifter: WIDTH must be >= 2 (got %0d); a one-bit ",
                 "shifter has nothing to shift"}, WIDTH);
    end
  end
`endif

endmodule

`default_nettype wire
