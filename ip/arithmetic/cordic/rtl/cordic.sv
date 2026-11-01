//=============================================================================
// Module      : cordic
// Category    : arithmetic
// Description : Iterative CORDIC in circular coordinates, supporting both
//               rotation mode (sine and cosine) and vectoring mode (magnitude
//               and arctangent).
//
// CORDIC computes trigonometric functions using only additions, subtractions
// and shifts - no multiplier and no lookup table of function values. That is
// why it survives: on a device with no spare DSP slices it is often the only
// way to get a sine at all, and its cost is almost independent of which
// function is being computed.
//
// HOW IT WORKS
//   Each iteration rotates the vector (x, y) by a fixed angle atan(2**-i),
//   choosing the direction to drive one variable towards zero. Because the
//   rotation angle is atan(2**-i), the rotation matrix entries are 1 and
//   2**-i, so the "multiply" is a shift:
//
//     x' = x -/+ (y >>> i)
//     y' = y +/- (x >>> i)
//     z' = z -/+ atan(2**-i)
//
//   ROTATION mode drives z towards zero, so the vector ends up rotated by the
//   requested angle. Starting from (1/K, 0) it produces (cos z, sin z).
//
//   VECTORING mode drives y towards zero, so the vector ends up on the x
//   axis. x then holds K times the magnitude and z has accumulated the
//   original angle, which is atan(y/x).
//
// THE GAIN
//   The rotations are not unit length - each scales the vector by
//   sqrt(1 + 2**-2i) - so the result is multiplied by a constant
//   K ~ 1.6467602581210654. This block does not divide it out, because the
//   correction depends on what the caller wants: a sine generator folds 1/K
//   into its amplitude for free and pays nothing, while a magnitude
//   computation needs a real multiply.
//
//   For callers that do need it:
//     1/K = 0.6072529350088813
//         = 32'd1304065748 at 31 fractional bits
//     Pre-scaling the input by 1/K, rather than scaling the output, is usually
//     cheaper: it is one multiply instead of two when both x and y matter.
//
//   The constant is documented here rather than declared as an unused
//   localparam, so that the RTL contains no dead code.
//
// CONVERGENCE RANGE
//   The circular CORDIC converges for |z| <= ~1.7433 radians, a little beyond
//   pi/2. Angles outside that must be folded into the first or fourth quadrant
//   before being presented, and the sign of the result corrected afterwards.
//   The block flags an out-of-range angle rather than returning a quietly
//   wrong answer.
//
// NUMBER FORMATS
//   Data  signed Q(WIDTH-2): 1.0 is 2**(WIDTH-2), range [-2, 2).
//   Angle signed Q(WIDTH-1) scaled by pi: pi is 2**(WIDTH-1), so the angle
//         covers [-pi, pi) across the full signed range. This is the
//         representation that makes the arctangent table exact at every
//         WIDTH: the canonical table below is stored at 31 fractional bits
//         and shifted down, rather than being regenerated per width.
//
// Parameters
//   WIDTH       Data and angle width. 8 to 32.
//   ITERATIONS  Rotation steps. Accuracy is about one bit per iteration, so
//               there is nothing to gain beyond WIDTH.
//
// Latency     : ITERATIONS + 2 cycles per operation
// Throughput  : one operation per ITERATIONS + 2 cycles; not pipelined
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module cordic #(
    parameter int unsigned WIDTH      = 16,
    parameter int unsigned ITERATIONS = 16
) (
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire                     s_valid,
    output logic                    s_ready,
    // 0 = rotation (x,y,z) -> (K*(x cos z - y sin z), K*(x sin z + y cos z), 0)
    // 1 = vectoring (x,y,z) -> (K*sqrt(x^2+y^2), 0, z + atan(y/x))
    input  wire                     mode_vectoring,
    input  wire signed [WIDTH-1:0]  x_in,
    input  wire signed [WIDTH-1:0]  y_in,
    input  wire signed [WIDTH-1:0]  z_in,

    output logic                    m_valid,
    input  wire                     m_ready,
    output logic signed [WIDTH-1:0] x_out,
    output logic signed [WIDTH-1:0] y_out,
    output logic signed [WIDTH-1:0] z_out,
    output logic                    out_of_range
);

  //---------------------------------------------------------------------------
  // Canonical arctangent table: atan(2**-i) / pi, at 31 fractional bits.
  //
  // Stored once at full precision and shifted to the working width at
  // elaboration, so every WIDTH gets the correctly rounded table without a
  // per-width regeneration step. Generated from
  //   round(atan(2**-i) / pi * 2**31)
  //
  // Written as a function over a case statement rather than as an unpacked
  // array localparam. The array form is legal SystemVerilog, but several
  // synthesis front ends - Yosys among them - do not accept unpacked
  // parameter arrays, and a vendor-independent block has to elaborate on all
  // of them. The case form maps to the same constant ROM everywhere.
  //---------------------------------------------------------------------------
  localparam int unsigned CANON_FRAC = 31;

  function automatic logic [31:0] atan_canon(input logic [4:0] index);
    unique case (index)
      5'd0:  atan_canon = 32'd536870912;
      5'd1:  atan_canon = 32'd316933406;
      5'd2:  atan_canon = 32'd167458907;
      5'd3:  atan_canon = 32'd85004756;
      5'd4:  atan_canon = 32'd42667331;
      5'd5:  atan_canon = 32'd21354465;
      5'd6:  atan_canon = 32'd10679838;
      5'd7:  atan_canon = 32'd5340245;
      5'd8:  atan_canon = 32'd2670163;
      5'd9:  atan_canon = 32'd1335087;
      5'd10: atan_canon = 32'd667544;
      5'd11: atan_canon = 32'd333772;
      5'd12: atan_canon = 32'd166886;
      5'd13: atan_canon = 32'd83443;
      5'd14: atan_canon = 32'd41722;
      5'd15: atan_canon = 32'd20861;
      5'd16: atan_canon = 32'd10430;
      5'd17: atan_canon = 32'd5215;
      5'd18: atan_canon = 32'd2608;
      5'd19: atan_canon = 32'd1304;
      5'd20: atan_canon = 32'd652;
      5'd21: atan_canon = 32'd326;
      5'd22: atan_canon = 32'd163;
      5'd23: atan_canon = 32'd81;
      5'd24: atan_canon = 32'd41;
      5'd25: atan_canon = 32'd20;
      5'd26: atan_canon = 32'd10;
      5'd27: atan_canon = 32'd5;
      5'd28: atan_canon = 32'd3;
      5'd29: atan_canon = 32'd1;
      5'd30: atan_canon = 32'd1;
      default: atan_canon = 32'd0;
    endcase
  endfunction

  // The angle format has WIDTH-1 fractional bits relative to pi.
  localparam int unsigned ANGLE_SHIFT = CANON_FRAC - (WIDTH - 1);

  //---------------------------------------------------------------------------
  // Working registers.
  //
  // Two guard bits above WIDTH on x and y: the intermediate vector grows by
  // the CORDIC gain during the iteration, and truncating to WIDTH would clip a
  // result that is in range once the gain is accounted for.
  //---------------------------------------------------------------------------
  localparam int unsigned EXT_WIDTH = WIDTH + 2;
  localparam int unsigned CNT_WIDTH = $clog2(ITERATIONS + 1);

  typedef enum logic [1:0] { S_IDLE, S_ITERATE, S_PRESENT } state_e;

  state_e                     state_q;
  logic [CNT_WIDTH-1:0]       count_q;
  logic signed [EXT_WIDTH-1:0] x_q;
  logic signed [EXT_WIDTH-1:0] y_q;
  logic signed [WIDTH-1:0]     z_q;
  logic                        mode_q;
  logic                        out_of_range_q;

  //---------------------------------------------------------------------------
  // Direction of this iteration.
  //
  // Rotation drives z to zero, so it follows the sign of z. Vectoring drives y
  // to zero, so it follows the opposite of the sign of y.
  //---------------------------------------------------------------------------
  logic direction_positive;

  assign direction_positive = mode_q ? (y_q < 0) : (z_q >= 0);

  //---------------------------------------------------------------------------
  // One rotation step
  //---------------------------------------------------------------------------
  logic signed [EXT_WIDTH-1:0] x_shifted;
  logic signed [EXT_WIDTH-1:0] y_shifted;
  logic signed [WIDTH-1:0]     angle_step;

  assign x_shifted = x_q >>> count_q;
  assign y_shifted = y_q >>> count_q;
  // The index is widened to five bits explicitly: the table always has 32
  // entries, while count_q is only as wide as ITERATIONS requires.
  assign angle_step = WIDTH'(atan_canon(5'(count_q)) >> ANGLE_SHIFT);

  //---------------------------------------------------------------------------
  // Convergence check on the requested angle.
  //
  // 1.7433 radians is 0.5549 * pi, which in the angle format is
  // 0.5549 * 2**(WIDTH-1).
  //---------------------------------------------------------------------------
  localparam logic [WIDTH-1:0] ANGLE_LIMIT =
      WIDTH'((32'd1191182336) >> (32 - WIDTH));   // round(0.5549 * 2**31)

  logic angle_too_large;
  assign angle_too_large = (z_in > signed'(ANGLE_LIMIT)) ||
                           (z_in < -signed'(ANGLE_LIMIT));

  //---------------------------------------------------------------------------
  // Control and datapath
  //---------------------------------------------------------------------------
  assign s_ready = (state_q == S_IDLE);
  assign m_valid = (state_q == S_PRESENT);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q        <= S_IDLE;
      count_q        <= '0;
      x_q            <= '0;
      y_q            <= '0;
      z_q            <= '0;
      mode_q         <= 1'b0;
      out_of_range_q <= 1'b0;
    end else begin
      unique case (state_q)
        S_IDLE: begin
          if (s_valid) begin
            x_q            <= EXT_WIDTH'(x_in);
            y_q            <= EXT_WIDTH'(y_in);
            z_q            <= z_in;
            mode_q         <= mode_vectoring;
            count_q        <= '0;
            out_of_range_q <= !mode_vectoring && angle_too_large;
            state_q        <= S_ITERATE;
          end
        end

        S_ITERATE: begin
          if (direction_positive) begin
            x_q <= x_q - y_shifted;
            y_q <= y_q + x_shifted;
            z_q <= z_q - angle_step;
          end else begin
            x_q <= x_q + y_shifted;
            y_q <= y_q - x_shifted;
            z_q <= z_q + angle_step;
          end

          count_q <= count_q + CNT_WIDTH'(1);
          if (count_q == CNT_WIDTH'(ITERATIONS - 1)) begin
            state_q <= S_PRESENT;
          end
        end

        S_PRESENT: begin
          if (m_ready) begin
            state_q <= S_IDLE;
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end

  assign x_out        = x_q[WIDTH-1:0];
  assign y_out        = y_q[WIDTH-1:0];
  assign z_out        = z_q;
  assign out_of_range = out_of_range_q;

  //---------------------------------------------------------------------------
  // Elaboration-time checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (WIDTH < 8 || WIDTH > 32) begin
      $fatal(1, {"cordic: WIDTH must be between 8 and 32 (got %0d); the ",
                 "arctangent table is stored at 31 fractional bits"}, WIDTH);
    end
    if (ITERATIONS < 2 || ITERATIONS > 32) begin
      $fatal(1, "cordic: ITERATIONS must be between 2 and 32 (got %0d)",
             ITERATIONS);
    end
    if (ITERATIONS > WIDTH) begin
      $display({"cordic: note - ITERATIONS (%0d) exceeds WIDTH (%0d); ",
                "accuracy is limited to about one bit per iteration, so the ",
                "extra steps cost cycles without improving the result"},
               ITERATIONS, WIDTH);
    end
  end
`endif

endmodule

`default_nettype wire
