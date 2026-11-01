//=============================================================================
// Module      : clk_gate_formal
// Category    : clocking
// Description : Formal property wrapper for clk_gate.
//
// Proved with free-running clocks (FORMAL_MULTICLOCK): the clock, enable
// and test_en are free inputs that may change on any solver step - enable
// included while the clock is high, which is exactly what a clock gate has
// to survive. For every input sequence:
//
//   NO GLITCH   while the clock holds its level, the gated clock holds its
//               level; the gated clock rises only on a rising clock edge and
//               falls only on a falling one, so every high pulse it produces
//               is a whole high phase of the clock
//   FUNCTION    during a high phase the gated clock is (enable | test_en) as
//               it stood on the last step before the clock rose, and while
//               the clock is low the gated clock is low
//
// Covers: a gated pulse, a suppressed pulse, enable changing during a high
// phase with no effect, and test_en alone passing the clock.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module clk_gate_formal (
    input wire clk,
    input wire enable,
    input wire test_en
);

  (* gclk *) reg gclk;

  wire gated_clk;

  clk_gate dut (.clk(clk), .enable(enable), .test_en(test_en), .gated_clk(gated_clk));

  logic p_clk = 1'b0, p_gated = 1'b0, p_enable = 1'b0;
  logic open_at_rise = 1'b0;     // enable | test_en on the last step the clock was low
  logic started = 1'b0;

  always @(posedge gclk) begin
    started  <= 1'b1;
    p_clk    <= clk;
    p_gated  <= gated_clk;
    p_enable <= enable;
    if (!clk) open_at_rise <= enable | test_en;
  end

  // The latch starts transparent: the clock is low at time zero.
  initial assume (!clk);

  always @(*) begin
    if (started) begin
      if (clk == p_clk) assert (gated_clk == p_gated);
      if (gated_clk && !p_gated) assert (clk && !p_clk);
      if (!gated_clk && p_gated) assert (!clk && p_clk);
    end
    if (!clk) assert (!gated_clk);
    if (clk && started) assert (gated_clk == open_at_rise);
  end

  always @(*) begin
    if (started) begin
      cover (gated_clk && !p_gated);
      cover (clk && !p_clk && !gated_clk);
      cover (clk && p_clk && gated_clk && enable != p_enable);
      cover (gated_clk && !enable && test_en);
    end
  end

endmodule

`default_nettype wire
