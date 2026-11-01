//=============================================================================
// Module      : systolic_pe
// Category    : ml
// Description : Weight-stationary processing element for an int8 systolic
//               matrix-multiply array: one multiply-accumulate per cycle with
//               a double-buffered weight register.
//
// The element holds one weight and sees one activation per cycle. It adds the
// product to the partial sum arriving from the north and hands the total to
// the south, while passing the activation on to the east. An array of these
// computes a matrix product with no interconnect other than the wires between
// neighbours, which is the whole point of the systolic arrangement: every
// signal is a register-to-register hop between adjacent cells, so the array
// scales without the fanout of a broadcast bus.
//
// WEIGHT DOUBLE BUFFERING
//   The weight path is two registers deep. `w_shift` moves the shift register
//   chain by one cell, and `w_commit` copies the shift register into the
//   register the multiplier actually reads. The separation is what allows the
//   next weight tile to be loaded through the array while the current tile is
//   still computing - without it, loading weights would cost as many idle
//   cycles as the array is deep, on every tile.
//
// SHIFT DIRECTION
//   The chain runs south to north: `w_in` comes from the cell below and
//   `w_out` goes to the cell above. That is the direction which makes a host
//   push weight rows in their natural order, row 0 first. A north-to-south
//   chain would require the host to reverse them, which is a standing
//   invitation to an off-by-one that only shows up as slightly wrong numbers.
//
// NO ENABLE
//   The element cannot be stalled. Back-pressure in an array of these is
//   handled by tagging data with a valid bit that travels alongside it, not
//   by gating the pipeline: a clock enable on every cell of a large array is
//   a fanout problem, and it prevents the multiply-accumulate from being
//   absorbed into a DSP block on the targets that have them. Cycles with
//   nothing to do carry a zero activation, which contributes nothing.
//
// Parameters
//   DATA_WIDTH  Activation and weight width, two's complement. 2 to 18.
//   ACC_WIDTH   Partial sum width, two's complement.
//               Must be >= 2*DATA_WIDTH, and in practice needs
//               2*DATA_WIDTH + $clog2(ROWS) to hold a full column sum.
//
// Latency     : 1 cycle, activation to psum_out and to a_out
// Throughput  : one multiply-accumulate per cycle
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module systolic_pe #(
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned ACC_WIDTH  = 32
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // Weight load chain, south to north
    input  wire                   w_shift,
    input  wire                   w_commit,
    input  wire  [DATA_WIDTH-1:0] w_in,
    output logic [DATA_WIDTH-1:0] w_out,

    // Activation, west to east
    input  wire  [DATA_WIDTH-1:0] a_in,
    output logic [DATA_WIDTH-1:0] a_out,

    // Partial sum, north to south
    input  wire  [ACC_WIDTH-1:0]  psum_in,
    output logic [ACC_WIDTH-1:0]  psum_out
);

  localparam int unsigned PRODUCT_WIDTH = 2 * DATA_WIDTH;

  logic [DATA_WIDTH-1:0] w_shift_q;   // in the load chain, not yet in use
  logic [DATA_WIDTH-1:0] w_q;         // what the multiplier reads

  assign w_out = w_shift_q;

  //---------------------------------------------------------------------------
  // Weight path.
  //
  // Commit takes priority over shift on the rare cycle where both are asserted
  // so that a commit always publishes the tile that has just finished loading,
  // never a half-shifted one.
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      w_shift_q <= '0;
      w_q       <= '0;
    end else begin
      if (w_shift) begin
        w_shift_q <= w_in;
      end
      if (w_commit) begin
        w_q <= w_shift_q;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Multiply-accumulate.
  //
  // The product is sign-extended to the accumulator width before the add. The
  // explicit cast matters: without it the addition would be performed at the
  // product width and the carry out of bit 2*DATA_WIDTH-1 would be lost.
  //---------------------------------------------------------------------------
  logic [PRODUCT_WIDTH-1:0] product;
  logic [ACC_WIDTH-1:0]     product_extended;

  assign product          = PRODUCT_WIDTH'($signed(w_q) * $signed(a_in));
  assign product_extended = ACC_WIDTH'(signed'(product));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_out    <= '0;
      psum_out <= '0;
    end else begin
      a_out    <= a_in;
      psum_out <= psum_in + product_extended;
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DATA_WIDTH < 2) begin
      $fatal(1, "systolic_pe: DATA_WIDTH must be >= 2 (got %0d)", DATA_WIDTH);
    end
    if (ACC_WIDTH < PRODUCT_WIDTH) begin
      $fatal(1, {"systolic_pe: ACC_WIDTH (%0d) must be at least 2*DATA_WIDTH ",
                 "(%0d), or a single product cannot be represented"},
             ACC_WIDTH, PRODUCT_WIDTH);
    end
  end

  // A partial sum that wraps is silent corruption: the result stays in range
  // and looks plausible. Catching it here is what turns an undersized
  // ACC_WIDTH from a debugging session into an error message.
  logic signed [ACC_WIDTH-1:0] psum_in_s;
  logic signed [ACC_WIDTH-1:0] sum_s;
  assign psum_in_s = $signed(psum_in);
  assign sum_s     = $signed(psum_in) + $signed(product_extended);

  property p_no_accumulator_overflow;
    @(posedge clk) disable iff (!rst_n)
      ((psum_in_s[ACC_WIDTH-1] == product_extended[ACC_WIDTH-1]) |->
       (sum_s[ACC_WIDTH-1] == psum_in_s[ACC_WIDTH-1]));
  endproperty
  a_no_accumulator_overflow : assert property (p_no_accumulator_overflow)
    else $error("systolic_pe: partial sum overflowed %0d bits", ACC_WIDTH);
`endif

endmodule

`default_nettype wire
