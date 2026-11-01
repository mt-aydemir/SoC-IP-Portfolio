//=============================================================================
// Module      : lfsr_rng_formal
// Category    : crypto
// Description : Formal property wrapper for lfsr_rng.
//
// Proves, for every input sequence from reset, that the block is the
// generator its header describes: a bit-serial model of
// b[t] = b[t-8] ^ b[t-6] ^ b[t-5] ^ b[t-4], advanced three steps per draw and
// reseeded on seed_load with zero replaced by 1, predicts m_data on every
// cycle - which covers holding a draw under a stall, the seed's priority over
// m_ready and the reset value - and its state never reaches zero. m_valid is
// low only on the first cycle after reset.
//
// The design's state register is probed and must equal the model's: with
// three bits per draw from eight bits of state, a draw held under a long
// stall hides the other five, and without the probe induction could not
// rule out an unreachable start in which only they differ.
//
// Covers show the properties are not vacuous: a zero seed is loaded and its
// first draw seen, a draw is held for two cycles, and the draw 3'b101 is
// reached.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module lfsr_rng_formal (
    input wire       clk,
    input wire       rst_n,
    input wire       seed_load,
    input wire [7:0] seed,
    input wire       m_ready
);

  localparam int unsigned W = 8;
  localparam int unsigned S = 3;

  logic         m_valid;
  logic [S-1:0] m_data;

  lfsr_rng #(.WIDTH(W), .STEPS(S), .SEED(64'd1)) dut (
      .clk(clk), .rst_n(rst_n), .seed_load(seed_load), .seed(seed),
      .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data));

  // formal-connect: f_state = dut.state
  (* keep *) wire [W-1:0] f_state;

  // Reference: the recurrence one bit at a time.
  function automatic logic [W-1:0] model_draw(input logic [W-1:0] s);
    logic [W-1:0] r;
    r = s;
    for (int i = 0; i < S; i++) r = {r[W-2:0], r[7] ^ r[5] ^ r[4] ^ r[3]};
    model_draw = r;
  endfunction

  logic [W-1:0] model;
  logic         started;     // a cycle has passed since reset was released

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      model   <= model_draw(W'(1));
      started <= 1'b0;
    end else begin
      started <= 1'b1;
      if (seed_load)                model <= model_draw(seed == '0 ? W'(1) : seed);
      else if (m_valid && m_ready)  model <= model_draw(model);
    end
  end

  initial assume (!rst_n);

  always @(*) begin
    if (rst_n) begin
      assert (m_data == model[S-1:0]);
      assert (f_state == model);
      assert (model != '0);
      assert (m_valid == started);
    end
  end

  // Non-vacuity.
  logic past_zero_seed, held;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      past_zero_seed <= 1'b0;
      held           <= 1'b0;
    end else begin
      past_zero_seed <= seed_load && seed == '0;
      held           <= m_valid && !m_ready && !seed_load;
    end
  end

  always @(*) begin
    if (rst_n) begin
      cover (past_zero_seed && m_valid);
      cover (held && m_valid && !m_ready);
      cover (m_data == 3'b101);
    end
  end

endmodule

`default_nettype wire
