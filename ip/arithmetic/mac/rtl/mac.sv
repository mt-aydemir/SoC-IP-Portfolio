//=============================================================================
// Module      : mac
// Category    : arithmetic
// Description : Multiply-accumulate: acc <- acc + a*b, with optional
//               saturation and a wider accumulator than the product.
//
// The multiply-accumulate is the inner loop of every filter, correlation and
// matrix product, which is why it exists as a block rather than as two blocks
// wired together by each caller: getting the accumulator width and the clear
// timing right is the part people get wrong, and doing it once here means
// doing it right once.
//
// STRUCTURE
//   The block instantiates `multiplier` and `accumulator` rather than
//   reimplementing either. What it adds is the part that is easy to get
//   wrong: the clear signal is delayed by exactly the multiplier's latency so
//   that it lands on the accumulator in the same cycle as the product it is
//   meant to precede.
//
//   Without that alignment a clear issued alongside the first sample of a new
//   frame would arrive one cycle early and wipe the accumulator *after* the
//   last product of the previous frame had already been added - or one cycle
//   late and discard the first product of the new one. Both failures produce
//   results that look almost right, which is what makes them expensive to
//   find.
//
// ACCUMULATOR WIDTH
//   The product needs A_WIDTH + B_WIDTH bits. Accumulating N of them needs
//   another $clog2(N) on top. ACC_WIDTH is the caller's decision because only
//   the caller knows N; the block checks that it is at least wide enough for a
//   single product and reports overflow if the real total exceeds it.
//
//   For a 16x16 filter with 128 taps that is 32 + 7 = 39 bits, so ACC_WIDTH
//   of 40 is the honest choice and 32 is the common mistake.
//
// Parameters
//   A_WIDTH    First operand width.
//   B_WIDTH    Second operand width.
//   ACC_WIDTH  Accumulator width. Must be >= A_WIDTH + B_WIDTH.
//   SIGNED     Interpret operands as two's complement. 0/1.
//   SATURATE   Clamp the accumulator instead of wrapping. 0/1.
//
// Latency     : 2 cycles from operands to the updated acc_out
// Throughput  : one multiply-accumulate per cycle
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module mac #(
    parameter int unsigned A_WIDTH   = 16,
    parameter int unsigned B_WIDTH   = 16,
    parameter int unsigned ACC_WIDTH = 40,
    parameter int unsigned SIGNED    = 1,
    parameter int unsigned SATURATE  = 0
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    in_valid,
    input  wire                    clear,      // zero the total with this sample
    input  wire  [A_WIDTH-1:0]     a,
    input  wire  [B_WIDTH-1:0]     b,

    output logic                   out_valid,
    output logic [ACC_WIDTH-1:0]   acc_out,
    output logic                   overflow
);

  localparam int unsigned P_WIDTH     = A_WIDTH + B_WIDTH;
  localparam int unsigned MUL_LATENCY = 1;

  //---------------------------------------------------------------------------
  // Product
  //---------------------------------------------------------------------------
  logic               product_valid;
  logic [P_WIDTH-1:0] product;

  multiplier #(
      .A_WIDTH (A_WIDTH),
      .B_WIDTH (B_WIDTH),
      .SIGNED  (SIGNED),
      .LATENCY (MUL_LATENCY)
  ) u_multiplier (
      .clk       (clk),
      .rst_n     (rst_n),
      .in_valid  (in_valid),
      .a         (a),
      .b         (b),
      .out_valid (product_valid),
      .product   (product)
  );

  //---------------------------------------------------------------------------
  // Clear alignment.
  //
  // Delayed by the multiplier's latency so it reaches the accumulator in the
  // same cycle as the product it accompanies. See the header for why an
  // unaligned clear is worth this much trouble.
  //---------------------------------------------------------------------------
  logic [MUL_LATENCY-1:0] clear_pipe_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      clear_pipe_q <= '0;
    end else begin
      clear_pipe_q[0] <= clear && in_valid;
      for (int unsigned s = 1; s < MUL_LATENCY; s++) begin
        clear_pipe_q[s] <= clear_pipe_q[s-1];
      end
    end
  end

  logic aligned_clear;
  assign aligned_clear = clear_pipe_q[MUL_LATENCY-1];

  //---------------------------------------------------------------------------
  // Accumulation.
  //
  // The clear and the add happen in the same cycle: `load` writes the product
  // as the new total, which is exactly "clear then accumulate this sample"
  // without costing a cycle or discarding the sample.
  //---------------------------------------------------------------------------
  logic [ACC_WIDTH-1:0] product_extended;

  if (SIGNED != 0) begin : g_signed_extend
    assign product_extended = ACC_WIDTH'(signed'(product));
  end else begin : g_zero_extend
    assign product_extended = ACC_WIDTH'(product);
  end

  accumulator #(
      .DATA_WIDTH (P_WIDTH),
      .ACC_WIDTH  (ACC_WIDTH),
      .SIGNED     (SIGNED),
      .SATURATE   (SATURATE)
  ) u_accumulator (
      .clk       (clk),
      .rst_n     (rst_n),
      .clear     (1'b0),
      .load      (aligned_clear && product_valid),
      .enable    (product_valid && !aligned_clear),
      .data_in   (product),
      .load_data (product_extended),
      .acc_out   (acc_out),
      .overflow  (overflow)
  );

  //---------------------------------------------------------------------------
  // out_valid marks the cycle in which acc_out has been updated, which is one
  // cycle after the product appeared.
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
    end else begin
      out_valid <= product_valid;
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (A_WIDTH < 1 || B_WIDTH < 1) begin
      $fatal(1, "mac: operand widths must be >= 1 (got %0d x %0d)",
             A_WIDTH, B_WIDTH);
    end
    if (ACC_WIDTH < P_WIDTH) begin
      $fatal(1, {"mac: ACC_WIDTH (%0d) must be at least A_WIDTH + B_WIDTH ",
                 "(%0d), or a single product cannot be represented"},
             ACC_WIDTH, P_WIDTH);
    end
  end
`endif

endmodule

`default_nettype wire
