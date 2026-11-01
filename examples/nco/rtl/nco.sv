//=============================================================================
// Module      : nco
// Category    : examples
// Description : Numerically controlled oscillator producing a quadrature
//               (cos, sin) stream, built from `accumulator` and `cordic`.
//
// An integration example rather than a catalogue IP. It exists to show three
// portfolio blocks composed into something a radio actually uses - the local
// oscillator of a digital down-converter - and to keep that composition
// compiling and verified as the blocks evolve.
//
// STRUCTURE
//   phase accumulator   `accumulator`, unsigned and wrapping, advanced by
//                       freq_word every time the CORDIC accepts a phase
//   quadrant fold       folds the phase into [-pi/2, pi/2), where the CORDIC
//                       converges, and remembers whether it did
//   sine/cosine         `cordic` in rotation mode, starting from (1/K, 0) so
//                       its gain lands the result at unit amplitude
//   unfold              negates both outputs when the phase was folded
//
// THE PHASE FORMAT IS THE POINT
//   The accumulator wraps at 2**WIDTH, so an unsigned phase of 2**WIDTH is a
//   full turn. Reinterpreted as signed, that same bit pattern is exactly the
//   CORDIC's angle format - pi is 2**(WIDTH-1) and the range is [-pi, pi). The
//   wrap-around of the accumulator is therefore the wrap-around of the angle,
//   and no conversion of any kind sits between the two blocks.
//
// QUADRANT FOLDING
//   The circular CORDIC converges only for |z| <= ~0.55 pi. A phase outside
//   [-pi/2, pi/2) is moved by pi - which in this format is a flip of the top
//   bit - and the result negated, using cos(t) = -cos(t - pi) and
//   sin(t) = -sin(t - pi). The phase lies outside that range exactly when
//   its top two bits differ.
//
// OUTPUT
//   One (cos, sin) pair per CORDIC operation, over a ready/valid stream. The
//   k-th sample is (cos, sin) of 2*pi * k * freq_word / 2**WIDTH, so the
//   output frequency is freq_word / 2**WIDTH cycles per sample, and a negative
//   freq_word (two's complement) rotates the other way.
//
// Parameters
//   WIDTH       Phase and sample width. 8 to 32.
//   ITERATIONS  CORDIC iterations. About one bit of accuracy each.
//
// Latency     : ITERATIONS + 2 cycles from reset to the first sample
// Throughput  : one sample per ITERATIONS + 2 cycles
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module nco #(
    parameter int unsigned WIDTH      = 16,
    parameter int unsigned ITERATIONS = 16
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // Phase increment per output sample; 2**WIDTH is one full turn.
    input  wire  [WIDTH-1:0]        freq_word,

    output logic                    m_valid,
    input  wire                     m_ready,
    output logic signed [WIDTH-1:0] cos_out,
    output logic signed [WIDTH-1:0] sin_out
);

  //---------------------------------------------------------------------------
  // 1/K in the CORDIC's data format, Q(WIDTH-2): round(2**(WIDTH-2) / K).
  // Derived from 1/K at 31 fractional bits, so it is exact at every WIDTH.
  //---------------------------------------------------------------------------
  localparam logic [31:0] INV_GAIN_Q31 = 32'd1304065748;   // 0.6072529350 * 2**31
  localparam logic [WIDTH-1:0] INV_GAIN =
      WIDTH'((64'(INV_GAIN_Q31) + (64'd1 << (32 - WIDTH))) >> (33 - WIDTH));

  //---------------------------------------------------------------------------
  // Phase accumulator. Advanced on the edge where the CORDIC accepts the
  // current phase, so the phase it holds is always the next one to compute.
  //---------------------------------------------------------------------------
  logic             cordic_ready;
  logic [WIDTH-1:0] phase;

  // Unconnected outputs are deliberate; each is annotated at its pin.
  /* verilator lint_off PINCONNECTEMPTY */
  accumulator #(
      .DATA_WIDTH (WIDTH),
      .ACC_WIDTH  (WIDTH),
      .SIGNED     (0),
      .SATURATE   (0)
  ) u_phase (
      .clk       (clk),
      .rst_n     (rst_n),
      .clear     (1'b0),
      .load      (1'b0),
      .enable    (cordic_ready),
      .data_in   (freq_word),
      .load_data ('0),
      .acc_out   (phase),
      .overflow  ()                 // wrapping is the intended behaviour
  );
  /* verilator lint_on PINCONNECTEMPTY */

  //---------------------------------------------------------------------------
  // Quadrant fold. Outside [-pi/2, pi/2) exactly when the top two bits differ;
  // moving by pi is a flip of the top bit.
  //---------------------------------------------------------------------------
  logic             fold;
  logic [WIDTH-1:0] folded_phase;
  logic             fold_q;

  assign fold         = phase[WIDTH-1] ^ phase[WIDTH-2];
  assign folded_phase = fold ? {~phase[WIDTH-1], phase[WIDTH-2:0]} : phase;

  // Remembered per operation: the CORDIC is iterative, so the fold of the
  // phase in flight has to outlive the accumulator moving on to the next one.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fold_q <= 1'b0;
    end else if (cordic_ready) begin
      fold_q <= fold;
    end
  end

  //---------------------------------------------------------------------------
  // Sine and cosine
  //---------------------------------------------------------------------------
  logic signed [WIDTH-1:0] cordic_x;
  logic signed [WIDTH-1:0] cordic_y;

  // Cast through named signals rather than in the port list: Yosys 0.67
  // aborts on a signed'() cast used directly as a port connection.
  logic signed [WIDTH-1:0] cordic_x_in;
  logic signed [WIDTH-1:0] cordic_z_in;

  assign cordic_x_in = signed'(INV_GAIN);
  assign cordic_z_in = signed'(folded_phase);

  // Unconnected outputs are deliberate; each is annotated at its pin.
  /* verilator lint_off PINCONNECTEMPTY */
  cordic #(
      .WIDTH      (WIDTH),
      .ITERATIONS (ITERATIONS)
  ) u_cordic (
      .clk            (clk),
      .rst_n          (rst_n),
      .s_valid        (1'b1),       // always another phase to compute
      .s_ready        (cordic_ready),
      .mode_vectoring (1'b0),
      .x_in           (cordic_x_in),
      .y_in           ('0),
      .z_in           (cordic_z_in),
      .m_valid        (m_valid),
      .m_ready        (m_ready),
      .x_out          (cordic_x),
      .y_out          (cordic_y),
      .z_out          (),
      .out_of_range   ()            // unreachable: the phase is always folded
  );
  /* verilator lint_on PINCONNECTEMPTY */

  //---------------------------------------------------------------------------
  // Unfold. The amplitude is 1.0 = 2**(WIDTH-2), well inside the range, so
  // negation cannot overflow.
  //---------------------------------------------------------------------------
  assign cos_out = fold_q ? -cordic_x : cordic_x;
  assign sin_out = fold_q ? -cordic_y : cordic_y;

  //---------------------------------------------------------------------------
  // Elaboration-time checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (WIDTH < 8 || WIDTH > 32) begin
      $fatal(1, "nco: WIDTH must be between 8 and 32 (got %0d)", WIDTH);
    end
  end
`endif

endmodule

`default_nettype wire
