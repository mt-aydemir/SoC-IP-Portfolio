//=============================================================================
// Module      : multiplier
// Category    : arithmetic
// Description : Parameterised pipelined multiplier, signed or unsigned, with a
//               configurable number of pipeline stages.
//
// The product is computed with the `*` operator rather than as a hand-written
// partial-product array. That is deliberate: every synthesiser recognises `*`
// and maps it onto whatever the target does best - a DSP slice on an FPGA, a
// Booth-encoded Wallace tree on an ASIC - and any hand-written structure would
// be worse on at least one of those and would defeat the mapping on all of
// them.
//
// PIPELINING
//   LATENCY registers are placed on the product. They are written as a plain
//   shift of the result rather than as hand-placed cuts inside the
//   multiplication, because retiming is the tool's job: given registers on the
//   output and a retiming pass enabled, synthesis will distribute them through
//   the partial-product tree far better than a human can, and on an FPGA it
//   will push them into the DSP slice's own pipeline registers where they cost
//   nothing at all.
//
//   The valid signal is pipelined alongside, so the interface stays usable
//   without the caller tracking latency by hand.
//
// WIDTH
//   The product is A_WIDTH + B_WIDTH bits, which is always wide enough: the
//   largest magnitude product of an m-bit and an n-bit value fits in m+n bits
//   in both the signed and unsigned interpretations. No overflow is possible
//   and none is reported.
//
// Parameters
//   A_WIDTH   Width of the first operand.
//   B_WIDTH   Width of the second operand.
//   SIGNED    Interpret both operands as two's complement. 0/1.
//   LATENCY   Pipeline registers on the output. Must be >= 1.
//
// Latency     : LATENCY clock cycles
// Throughput  : one multiplication per cycle
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module multiplier #(
    parameter int unsigned A_WIDTH = 16,
    parameter int unsigned B_WIDTH = 16,
    parameter int unsigned SIGNED  = 0,
    parameter int unsigned LATENCY = 1
) (
    input  wire                            clk,
    input  wire                            rst_n,

    input  wire                            in_valid,
    input  wire  [A_WIDTH-1:0]             a,
    input  wire  [B_WIDTH-1:0]             b,

    output logic                           out_valid,
    output logic [A_WIDTH+B_WIDTH-1:0]     product
);

  localparam int unsigned P_WIDTH   = A_WIDTH + B_WIDTH;
  localparam bit          IS_SIGNED = (SIGNED != 0);

  //---------------------------------------------------------------------------
  // The multiplication itself.
  //
  // Both operands are widened to the full product width before multiplying.
  // Doing it this way rather than relying on the operator's own width rules is
  // what makes the signed case correct: a signed multiply must sign-extend
  // both operands, and an expression that mixes a signed and an unsigned
  // operand is unsigned in SystemVerilog, which silently produces the wrong
  // answer for negative inputs.
  //---------------------------------------------------------------------------
  logic [P_WIDTH-1:0] product_comb;

  if (IS_SIGNED) begin : g_signed
    logic signed [P_WIDTH-1:0] a_ext;
    logic signed [P_WIDTH-1:0] b_ext;

    assign a_ext = P_WIDTH'(signed'(a));
    assign b_ext = P_WIDTH'(signed'(b));
    assign product_comb = P_WIDTH'(a_ext * b_ext);
  end else begin : g_unsigned
    assign product_comb = P_WIDTH'(a) * P_WIDTH'(b);
  end

  //---------------------------------------------------------------------------
  // Output pipeline.
  //
  // Deliberately a plain shift register on the result. Synthesis retiming
  // redistributes these registers into the partial-product tree, or into the
  // DSP slice's own pipeline stages, far more effectively than hand placement.
  //---------------------------------------------------------------------------
  logic [P_WIDTH-1:0] stage_q [LATENCY];
  logic [LATENCY-1:0] valid_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_q <= '0;
      for (int unsigned s = 0; s < LATENCY; s++) begin
        stage_q[s] <= '0;
      end
    end else begin
      // Shifted with a loop rather than a concatenation, so that LATENCY = 1
      // works: the slice in {valid_q[LATENCY-2:0], in_valid} would be
      // valid_q[-1:0] at that setting.
      valid_q[0] <= in_valid;
      stage_q[0] <= product_comb;
      for (int unsigned s = 1; s < LATENCY; s++) begin
        valid_q[s] <= valid_q[s-1];
        stage_q[s] <= stage_q[s-1];
      end
    end
  end

  assign product   = stage_q[LATENCY-1];
  assign out_valid = valid_q[LATENCY-1];

  //---------------------------------------------------------------------------
  // Elaboration-time checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (A_WIDTH < 1 || B_WIDTH < 1) begin
      $fatal(1, "multiplier: operand widths must be >= 1 (got %0d x %0d)",
             A_WIDTH, B_WIDTH);
    end
    if (LATENCY < 1) begin
      $fatal(1, {"multiplier: LATENCY must be >= 1 (got %0d); a combinational ",
                 "multiplier needs no clock, so use the operator directly"},
             LATENCY);
    end
  end
`endif

endmodule

`default_nettype wire
