//=============================================================================
// Module      : clk_mux_formal
// Category    : clocking
// Description : Formal property wrapper for clk_mux.
//
// Proved with free-running clocks (FORMAL_MULTICLOCK): both clocks, both
// resets and select are free inputs that may change on any solver step, so
// every ratio and phase between the clocks is explored, select changing at
// any moment included. Each reset is low at the start and released once,
// in either order. For every such sequence:
//
//   EXCLUSION   the two branch enables are never high together
//   SAFE EDGES  each enable changes only while its own clock is low, so it
//               can neither cut a high phase short nor start one part-way
//   NO GLITCH   the output rises only with a rising edge of the enabled
//               clock and falls only with a falling edge of the clock that
//               was driving it: every output high pulse is a whole high
//               phase of one input clock
//   REPORT      clk_active is the clock-1 enable; in reset clock 0 drives
//
// The enables and both synchroniser chains are probed. Induction needs the
// reachable states of the two branches, which come down to four rules per
// branch, checked against an exhaustive enumeration of the step semantics:
// at most one branch is active (its chain non-empty or its enable high);
// each chain is a thermometer code; an enable stays high with an empty chain
// only while its clock is high, between the rising edge that cleared the
// chain and the falling edge that drops the enable; and a full chain with
// the enable still low means the clock is high, between the rising edge that
// filled the chain and the falling edge that raises the enable.
//
// Covers: a switch to clock 1 and back to clock 0, and an output pulse from
// each clock.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module clk_mux_formal (
    input wire clk0,
    input wire clk1,
    input wire rst0_n,
    input wire rst1_n,
    input wire select
);

  (* gclk *) reg gclk;

  wire clk_active, clk_out;

  clk_mux #(.STAGES(2)) dut (
      .clk0(clk0), .clk1(clk1), .rst0_n(rst0_n), .rst1_n(rst1_n),
      .select(select), .clk_active(clk_active), .clk_out(clk_out));

  // formal-connect: f_en0 = dut.enable0
  // formal-connect: f_en1 = dut.enable1
  // formal-connect: f_sel0 = dut.sel0_q
  // formal-connect: f_sel1 = dut.sel1_q
  (* keep *) wire       f_en0, f_en1;
  (* keep *) wire [1:0] f_sel0, f_sel1;

  logic p_clk0 = 1'b0, p_clk1 = 1'b0, p_rst0 = 1'b0, p_rst1 = 1'b0;
  logic p_en0 = 1'b1, p_en1 = 1'b0, p_out = 1'b0;
  logic started = 1'b0;
  logic was1 = 1'b0, back0 = 1'b0;

  always @(posedge gclk) begin
    started <= 1'b1;
    p_clk0  <= clk0;
    p_clk1  <= clk1;
    p_rst0  <= rst0_n;
    p_rst1  <= rst1_n;
    p_en0   <= f_en0;
    p_en1   <= f_en1;
    p_out   <= clk_out;
    if (f_en1) was1 <= 1'b1;
    if (was1 && f_en0) back0 <= 1'b1;
  end

  initial assume (!rst0_n && !rst1_n);
  always @(*) begin
    if (p_rst0) assume (rst0_n);
    if (p_rst1) assume (rst1_n);
  end

  logic active0, active1;
  assign active0 = f_sel0 != 2'b00 || f_en0;
  assign active1 = f_sel1 != 2'b00 || f_en1;

  always @(*) begin
    assert (!(f_en0 && f_en1));
    // The reachable branch states
    assert (!(active0 && active1));
    assert (f_sel0 != 2'b10 && f_sel1 != 2'b10);
    if (f_en0) assert (f_sel0 == 2'b11 || (f_sel0 == 2'b00 && clk0));
    if (f_en1) assert (f_sel1 == 2'b11 || (f_sel1 == 2'b00 && clk1));
    if (f_sel0 == 2'b11 && !f_en0) assert (clk0);
    if (f_sel1 == 2'b11 && !f_en1) assert (clk1);
    assert (clk_active == f_en1);
    if (!rst0_n) assert (f_en0 && f_sel0 == 2'b11);
    if (!rst1_n) assert (!f_en1 && f_sel1 == 2'b00);
    if (started) begin
      if (f_en0 != p_en0) assert (!clk0);
      if (f_en1 != p_en1) assert (!clk1);
      if (clk_out && !p_out)
        assert ((clk0 && !p_clk0 && f_en0) || (clk1 && !p_clk1 && f_en1));
      if (!clk_out && p_out)
        assert ((!clk0 && p_clk0 && p_en0) || (!clk1 && p_clk1 && p_en1));
    end
  end

  always @(*) begin
    if (started) begin
      cover (back0);
      cover (clk_out && !p_out && f_en0);
      cover (clk_out && !p_out && f_en1);
    end
  end

endmodule

`default_nettype wire
