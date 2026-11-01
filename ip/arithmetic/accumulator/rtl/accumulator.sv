//=============================================================================
// Module      : accumulator
// Category    : arithmetic
// Description : Parameterised accumulator with load, clear, enable and
//               optional saturation.
//
// The accumulator is wider than its input, which is the whole point of having
// one as an IP rather than writing `sum <= sum + x` inline. Adding N values of
// DATA_WIDTH bits needs DATA_WIDTH + $clog2(N) bits to hold every possible
// result, and getting that width wrong is the most common defect in
// accumulate loops: the sum is correct for the test vectors and wraps on real
// data.
//
// GROWTH
//   ACC_WIDTH is the caller's decision because only the caller knows how many
//   values will be accumulated between clears. The block does not guess. What
//   it does do is report overflow, so a wrong choice is visible rather than
//   silent.
//
// SATURATION
//   With SATURATE set, the accumulator clamps at the limit instead of
//   wrapping. Signal processing wants this: an accumulator that wraps turns a
//   large sum into a large negative one, which in a filter is an audible
//   click, while one that clamps merely distorts. A statistics counter wants
//   the opposite, so the default is off.
//
//   Note that saturation is sticky in effect but not in state: once clamped
//   the accumulator stays at the limit only while inputs keep pushing it
//   there, and a subsequent input of the opposite sign moves it back. That is
//   deliberate - a latching saturation flag belongs to the consumer, and
//   `overflow` is provided for exactly that purpose.
//
// PRIORITY
//   clear beats load beats accumulate. Clear is the recovery path and must
//   always work, which is why nothing can mask it.
//
// Parameters
//   DATA_WIDTH  Width of the value added each cycle.
//   ACC_WIDTH   Width of the accumulator. Must be >= DATA_WIDTH.
//   SIGNED      Interpret both as two's complement. 0/1.
//   SATURATE    Clamp instead of wrapping. 0/1.
//
// Latency     : 1 cycle; acc_out reflects inputs applied on the previous edge
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module accumulator #(
    parameter int unsigned DATA_WIDTH = 16,
    parameter int unsigned ACC_WIDTH  = 32,
    parameter int unsigned SIGNED     = 1,
    parameter int unsigned SATURATE   = 0
) (
    input  wire                   clk,
    input  wire                   rst_n,

    input  wire                   clear,      // highest priority
    input  wire                   load,       // load_data replaces the total
    input  wire                   enable,     // add data_in this cycle
    input  wire  [DATA_WIDTH-1:0] data_in,
    input  wire  [ACC_WIDTH-1:0]  load_data,

    output logic [ACC_WIDTH-1:0]  acc_out,
    output logic                  overflow
);

  localparam bit IS_SIGNED   = (SIGNED   != 0);
  localparam bit DO_SATURATE = (SATURATE != 0);

  localparam logic [ACC_WIDTH-1:0] MAX_SIGNED   = {1'b0, {(ACC_WIDTH-1){1'b1}}};
  localparam logic [ACC_WIDTH-1:0] MIN_SIGNED   = {1'b1, {(ACC_WIDTH-1){1'b0}}};
  localparam logic [ACC_WIDTH-1:0] MAX_UNSIGNED = {ACC_WIDTH{1'b1}};

  //---------------------------------------------------------------------------
  // Widen the addend to the accumulator width.
  //
  // Sign extension for the signed case, zero extension otherwise. Getting this
  // wrong is silent: an unsigned extension of a negative value adds a huge
  // positive number instead of a small negative one, and the accumulator only
  // looks wrong once the inputs go negative.
  //---------------------------------------------------------------------------
  logic [ACC_WIDTH-1:0] addend;

  if (IS_SIGNED) begin : g_signed_extend
    assign addend = ACC_WIDTH'(signed'(data_in));
  end else begin : g_zero_extend
    assign addend = ACC_WIDTH'(data_in);
  end

  //---------------------------------------------------------------------------
  // The sum, one bit wider so the unsigned carry is available.
  //---------------------------------------------------------------------------
  logic [ACC_WIDTH:0]   wide_sum;
  logic [ACC_WIDTH-1:0] sum;
  logic                 carry_out;
  logic                 sum_overflow;

  assign wide_sum  = {1'b0, acc_out} + {1'b0, addend};
  assign sum       = wide_sum[ACC_WIDTH-1:0];
  assign carry_out = wide_sum[ACC_WIDTH];

  // Signed overflow: the operands agreed on a sign that the result does not.
  assign sum_overflow = IS_SIGNED
      ? ((acc_out[ACC_WIDTH-1] == addend[ACC_WIDTH-1]) &&
         (sum[ACC_WIDTH-1] != acc_out[ACC_WIDTH-1]))
      : carry_out;

  //---------------------------------------------------------------------------
  // Next value
  //---------------------------------------------------------------------------
  logic [ACC_WIDTH-1:0] next_acc;

  always_comb begin
    if (!DO_SATURATE || !sum_overflow) begin
      next_acc = sum;
    end else if (IS_SIGNED) begin
      // The shared operand sign says which limit was crossed.
      next_acc = acc_out[ACC_WIDTH-1] ? MIN_SIGNED : MAX_SIGNED;
    end else begin
      next_acc = MAX_UNSIGNED;
    end
  end

  //---------------------------------------------------------------------------
  // State
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_out  <= '0;
      overflow <= 1'b0;
    end else if (clear) begin
      acc_out  <= '0;
      overflow <= 1'b0;
    end else if (load) begin
      acc_out  <= load_data;
      overflow <= 1'b0;
    end else if (enable) begin
      acc_out  <= next_acc;
      overflow <= sum_overflow;
    end else begin
      overflow <= 1'b0;
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DATA_WIDTH < 1) begin
      $fatal(1, "accumulator: DATA_WIDTH must be >= 1 (got %0d)", DATA_WIDTH);
    end
    if (ACC_WIDTH < DATA_WIDTH) begin
      $fatal(1, {"accumulator: ACC_WIDTH (%0d) must be at least DATA_WIDTH ",
                 "(%0d), or the very first addend cannot be represented"},
             ACC_WIDTH, DATA_WIDTH);
    end
    if (ACC_WIDTH < 2) begin
      $fatal(1, "accumulator: ACC_WIDTH must be >= 2 (got %0d)", ACC_WIDTH);
    end
  end
`endif

endmodule

`default_nettype wire
