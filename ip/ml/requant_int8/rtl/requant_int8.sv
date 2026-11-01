//=============================================================================
// Module      : requant_int8
// Category    : ml
// Description : Quantised-neural-network requantisation stage: takes a wide
//               integer accumulator back down to an int8 activation with a
//               per-channel bias, a fixed-point scale, round-to-nearest and a
//               saturating clamp.
//
// A quantised convolution accumulates int8 products into a 32-bit total. That
// total is in the scale S_a * S_w, and the next layer wants its input in the
// scale S_out. The conversion is a multiply by the real number
// (S_a * S_w) / S_out, which is exactly what this block performs with a
// fixed-point multiplier and a right shift:
//
//     out = clamp( round( (acc + bias) * mult / 2**shift ) + out_zero_point,
//                  out_min, out_max )
//
// PARAMETERS ARE PER CHANNEL AND ARRIVE WITH THE DATA
//   bias, mult and shift are inputs rather than parameters because every
//   output channel of a layer has its own, and a per-channel-quantised network
//   is the normal case: one shared scale across a whole layer costs real
//   accuracy on depthwise convolutions in particular.
//
// ROUNDING
//   Round to nearest, ties away from zero, applied once to the full-width
//   product. The adjustment added before the arithmetic shift is `half` for a
//   positive product and `half - 1` for a negative one, which is the identity
//   that turns a floor-shift into a round-half-away-from-zero divide. It is
//   the same rule as gemmlowp's RoundingDivideByPOT.
//
//   Reference implementations in the TFLite lineage reach the same result in
//   two steps - a doubling high multiply that rounds, then a rounding shift -
//   and therefore round twice. Rounding once on the full product is at least
//   as accurate, but it means a result here can differ from such a reference
//   by one least significant bit. The C driver that ships with the
//   accelerator computes its expected values the same way this block does.
//
// ZERO POINTS
//   Only the output zero point appears here. The input zero point of an
//   asymmetrically quantised activation is folded into `bias` by the host,
//   using the identity
//
//       sum_k w[k] * (a[k] - z_a)  =  sum_k w[k] * a[k]  -  z_a * sum_k w[k]
//
//   where the correction term depends only on the weights, so it costs
//   nothing at run time. That is why the datapath in front of this block can
//   be purely signed int8 with no zero-point subtraction per multiply.
//
// FUSED ACTIVATION
//   ReLU is not a separate mode. A fused ReLU is expressed by the caller
//   raising out_min to the output zero point, and ReLU6 by additionally
//   lowering out_max; that is how a quantised graph represents it, and it
//   costs nothing because the clamp is present anyway for saturation.
//
// Parameters
//   ACC_WIDTH    Accumulator and bias width, two's complement.
//   MULT_WIDTH   Fixed-point multiplier width, unsigned.
//   SHIFT_WIDTH  Width of the shift amount, unsigned.
//   OUT_WIDTH    Output, zero point and clamp width, two's complement.
//
// Latency     : 3 cycles
// Throughput  : one result per cycle
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module requant_int8 #(
    parameter int unsigned ACC_WIDTH   = 32,
    parameter int unsigned MULT_WIDTH  = 24,
    parameter int unsigned SHIFT_WIDTH = 6,
    parameter int unsigned OUT_WIDTH   = 8
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    in_valid,
    input  wire  [ACC_WIDTH-1:0]   acc,             // signed
    input  wire  [ACC_WIDTH-1:0]   bias,            // signed
    input  wire  [MULT_WIDTH-1:0]  mult,            // unsigned
    input  wire  [SHIFT_WIDTH-1:0] shift,           // unsigned
    input  wire  [OUT_WIDTH-1:0]   out_zero_point,  // signed
    input  wire  [OUT_WIDTH-1:0]   out_min,         // signed
    input  wire  [OUT_WIDTH-1:0]   out_max,         // signed

    output logic                   out_valid,
    output logic [OUT_WIDTH-1:0]   out_data,        // signed
    output logic                   saturated
);

  // The bias add can carry out of the accumulator width, so the sum is kept
  // one bit wider rather than saturated: a bias large enough to overflow is a
  // host error, and truncating it here would hide it.
  localparam int unsigned SUM_WIDTH  = ACC_WIDTH + 1;
  // Signed sum times unsigned multiplier. The unsigned operand is widened by
  // one bit to make it signed, and the product of an m-bit and an n-bit signed
  // value needs m + n bits.
  localparam int unsigned PROD_WIDTH = SUM_WIDTH + MULT_WIDTH + 1;

  //---------------------------------------------------------------------------
  // Stage 1: bias
  //---------------------------------------------------------------------------
  logic                    valid_s1;
  logic signed [SUM_WIDTH-1:0]   sum_s1;
  logic        [MULT_WIDTH-1:0]  mult_s1;
  logic        [SHIFT_WIDTH-1:0] shift_s1;
  logic signed [OUT_WIDTH-1:0]   zero_point_s1;
  logic signed [OUT_WIDTH-1:0]   min_s1;
  logic signed [OUT_WIDTH-1:0]   max_s1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s1      <= 1'b0;
      sum_s1        <= '0;
      mult_s1       <= '0;
      shift_s1      <= '0;
      zero_point_s1 <= '0;
      min_s1        <= '0;
      max_s1        <= '0;
    end else begin
      valid_s1      <= in_valid;
      sum_s1        <= SUM_WIDTH'(signed'(acc)) + SUM_WIDTH'(signed'(bias));
      mult_s1       <= mult;
      shift_s1      <= shift;
      zero_point_s1 <= signed'(out_zero_point);
      min_s1        <= signed'(out_min);
      max_s1        <= signed'(out_max);
    end
  end

  //---------------------------------------------------------------------------
  // Stage 2: fixed-point scale
  //
  // The multiplier is unsigned - a quantisation scale is always positive - so
  // it is zero-extended by one bit before the multiply. Without that the
  // expression would be evaluated unsigned and every negative accumulator
  // would come out as a large positive number.
  //---------------------------------------------------------------------------
  logic                          valid_s2;
  logic signed [PROD_WIDTH-1:0]  product_s2;
  logic        [SHIFT_WIDTH-1:0] shift_s2;
  logic signed [OUT_WIDTH-1:0]   zero_point_s2;
  logic signed [OUT_WIDTH-1:0]   min_s2;
  logic signed [OUT_WIDTH-1:0]   max_s2;

  logic signed [MULT_WIDTH:0]    mult_signed;
  assign mult_signed = signed'({1'b0, mult_s1});

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_s2      <= 1'b0;
      product_s2    <= '0;
      shift_s2      <= '0;
      zero_point_s2 <= '0;
      min_s2        <= '0;
      max_s2        <= '0;
    end else begin
      valid_s2      <= valid_s1;
      product_s2    <= PROD_WIDTH'(sum_s1 * mult_signed);
      shift_s2      <= shift_s1;
      zero_point_s2 <= zero_point_s1;
      min_s2        <= min_s1;
      max_s2        <= max_s1;
    end
  end

  //---------------------------------------------------------------------------
  // Stage 3: round, offset, clamp
  //
  // Adding `half` to a positive product and `half - 1` to a negative one turns
  // the arithmetic shift - which floors - into a round to nearest with ties
  // away from zero. A shift of zero is the identity and must add nothing, or
  // every negative result would be pulled down by one.
  //---------------------------------------------------------------------------
  logic signed [PROD_WIDTH-1:0] half;
  logic signed [PROD_WIDTH-1:0] adjust;
  logic signed [PROD_WIDTH-1:0] rounded;
  logic signed [PROD_WIDTH-1:0] offset;

  always_comb begin
    half = (shift_s2 == '0) ? '0
                            : (PROD_WIDTH'(1) <<< (shift_s2 - SHIFT_WIDTH'(1)));

    if (shift_s2 == '0) begin
      adjust = '0;
    end else if (product_s2 < 0) begin
      adjust = half - PROD_WIDTH'(1);
    end else begin
      adjust = half;
    end

    rounded = (product_s2 + adjust) >>> shift_s2;
    offset  = rounded + PROD_WIDTH'(zero_point_s2);
  end

  logic signed [PROD_WIDTH-1:0] clamp_low;
  logic signed [PROD_WIDTH-1:0] clamp_high;
  logic signed [OUT_WIDTH-1:0]  clamped;
  logic                         clipped;

  always_comb begin
    clamp_low  = PROD_WIDTH'(min_s2);
    clamp_high = PROD_WIDTH'(max_s2);

    if (offset < clamp_low) begin
      clamped = min_s2;
      clipped = 1'b1;
    end else if (offset > clamp_high) begin
      clamped = max_s2;
      clipped = 1'b1;
    end else begin
      clamped = OUT_WIDTH'(offset);
      clipped = 1'b0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_valid <= 1'b0;
      out_data  <= '0;
      saturated <= 1'b0;
    end else begin
      out_valid <= valid_s2;
      out_data  <= clamped;
      saturated <= valid_s2 && clipped;
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (ACC_WIDTH < 4) begin
      $fatal(1, "requant_int8: ACC_WIDTH must be >= 4 (got %0d)", ACC_WIDTH);
    end
    if (MULT_WIDTH < 2) begin
      $fatal(1, "requant_int8: MULT_WIDTH must be >= 2 (got %0d)", MULT_WIDTH);
    end
    if (SHIFT_WIDTH < 1) begin
      $fatal(1, "requant_int8: SHIFT_WIDTH must be >= 1 (got %0d)", SHIFT_WIDTH);
    end
    if (OUT_WIDTH < 2) begin
      $fatal(1, "requant_int8: OUT_WIDTH must be >= 2 (got %0d)", OUT_WIDTH);
    end
    if (OUT_WIDTH > ACC_WIDTH) begin
      $fatal(1, {"requant_int8: OUT_WIDTH (%0d) exceeds ACC_WIDTH (%0d); this ",
                 "block narrows, it does not widen"}, OUT_WIDTH, ACC_WIDTH);
    end
  end

  // An inverted clamp window silently forces every output to out_max, which
  // looks like a saturating layer rather than like the parameter mistake it is.
  property p_clamp_window_ordered;
    @(posedge clk) disable iff (!rst_n)
      in_valid |-> (signed'(out_min) <= signed'(out_max));
  endproperty
  a_clamp_window_ordered : assert property (p_clamp_window_ordered)
    else $error("requant_int8: out_min (%0d) is above out_max (%0d)",
                signed'(out_min), signed'(out_max));

  // A shift wide enough to make the rounding term overflow the product would
  // corrupt the result rather than merely lose precision.
  property p_shift_in_range;
    @(posedge clk) disable iff (!rst_n)
      in_valid |-> (shift < SHIFT_WIDTH'(PROD_WIDTH));
  endproperty
  a_shift_in_range : assert property (p_shift_in_range)
    else $error("requant_int8: shift %0d must be below %0d", shift, PROD_WIDTH);

  // The clamp window travelling with the result, so the output check compares
  // against the window that produced it rather than the one currently applied.
  logic signed [OUT_WIDTH-1:0] min_s3;
  logic signed [OUT_WIDTH-1:0] max_s3;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      min_s3 <= '0;
      max_s3 <= '0;
    end else begin
      min_s3 <= min_s2;
      max_s3 <= max_s2;
    end
  end

  // The result must be inside the window the caller asked for, always.
  property p_output_in_window;
    @(posedge clk) disable iff (!rst_n)
      out_valid |-> ((signed'(out_data) >= min_s3) &&
                     (signed'(out_data) <= max_s3));
  endproperty
  a_output_in_window : assert property (p_output_in_window)
    else $error("requant_int8: output %0d escaped the clamp window [%0d, %0d]",
                signed'(out_data), min_s3, max_s3);
`endif

endmodule

`default_nettype wire
