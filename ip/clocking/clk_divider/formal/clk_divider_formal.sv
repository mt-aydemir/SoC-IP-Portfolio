//=============================================================================
// Module      : clk_divider_formal
// Category    : clocking
// Description : Formal property wrapper for clk_divider.
//
// Proved with free-running clocks (FORMAL_MULTICLOCK), because the odd
// divider uses both clock edges: the clock, the reset and each instance's
// enable are free inputs that may change on any solver step. The reset is
// low at the start and released once. Two instances, DIVISOR = 3 (odd, both
// edges) and DIVISOR = 4 (even, rising edges only). For every input
// sequence:
//
//   NO GLITCH  clk_out changes only on a clock transition: the even divider
//              only on rising edges, the odd one rising on a falling edge -
//              when the falling-edge phase flop catches up - and falling on a
//              rising edge
//   DUTY       in steady operation every high phase and every low phase of
//              clk_out lasts exactly DIVISOR half-periods of the clock - a
//              50% duty cycle at both divisors - and no phase is longer
//   ENABLE     after a rising edge that samples enable low, clk_out is low
//   CLK_EN     clk_en is high for one in every DIVISOR clock cycles, as a
//              flop on the rising edge samples it, and never while disabled
//
// The counters and, for the odd divider, both phase flops are probed. A
// stopped clock freezes them indefinitely, so induction needs them tied to
// the wrapper's counts: on every step without a clock transition the
// counter gives the half-periods elapsed in the current phase and the
// rising edges since clk_en was last sampled, and the odd divider's phase
// flops say where in the low phase it is. These relations are written for
// the two divisors proved, 3 and 4.
//
// Covers: each divider completes a full period in steady operation, and
// the odd divider is disabled in the middle of a high phase.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module clk_divider_formal (
    input wire       clk,
    input wire       rst_n,
    input wire [1:0] enable
);

  (* gclk *) reg gclk;

  initial assume (!rst_n);
  logic p_rst_root = 1'b0;
  always @(posedge gclk) p_rst_root <= rst_n;
  always @(*) if (p_rst_root) assume (rst_n);

  // Probe paths run from this module, so each checker's are listed here.
  // formal-connect: u_odd.f_count = u_odd.dut.g_divide.count_q
  // formal-connect: u_even.f_count = u_even.dut.g_divide.count_q
  // formal-connect: u_odd.g_odd_probes.f_rise_q = u_odd.dut.g_divide.g_odd.phase_rise_q
  // formal-connect: u_odd.g_odd_probes.f_fall_q = u_odd.dut.g_divide.g_odd.phase_fall_q
  clk_divider_check #(.D(3)) u_odd  (.clk(clk), .rst_n(rst_n), .enable(enable[0]));
  clk_divider_check #(.D(4)) u_even (.clk(clk), .rst_n(rst_n), .enable(enable[1]));

endmodule

module clk_divider_check #(
    parameter int unsigned D = 3
) (
    input wire clk,
    input wire rst_n,
    input wire enable
);

  // The solver's clock is declared here, not passed in: Yosys gives the
  // gclk attribute its meaning only in the module that declares it.
  (* gclk *) reg gclk;

  logic clk_en, clk_out;

  clk_divider #(.DIVISOR(D)) dut (
      .clk(clk), .rst_n(rst_n), .enable(enable), .clk_en(clk_en), .clk_out(clk_out));

  (* keep *) wire [1:0] f_count;       // probes: see the top module
  logic f_rise, f_fall;
  if (D % 2 == 1) begin : g_odd_probes
    (* keep *) wire f_rise_q, f_fall_q;
    assign f_rise = f_rise_q;
    assign f_fall = f_fall_q;
  end else begin : g_even_probes
    assign f_rise = 1'b0;
    assign f_fall = 1'b0;
  end

  logic p_clk = 1'b0, p_rst = 1'b0, p_en = 1'b0, p_out = 1'b0, p_clk_en = 1'b0;
  logic started = 1'b0;
  logic [2:0] half = '0;     // clock transitions in the current clk_out phase
  logic       steady = 1'b0; // the current phase began in enabled operation
  logic       off = 1'b1;    // the last counted rising edge sampled enable low
  logic [2:0] gap = '0;      // counted rising edges since clk_en was sampled high
  logic       gap_ok = 1'b0;
  logic       full_period = 1'b0;
  logic       tog, rise, fall, cnt_edge, change, cut, steady_now;

  assign tog    = clk != p_clk;
  assign rise   = clk && !p_clk;
  assign fall   = !clk && p_clk;
  assign cnt_edge   = rise && p_rst && rst_n;     // a rising edge the counters see
  assign change = clk_out != p_out;
  assign cut    = (cnt_edge && !p_en) || !rst_n;   // this step disables or resets
  assign steady_now = steady && !cut;

  always @(posedge gclk) begin
    started  <= 1'b1;
    p_clk    <= clk;
    p_rst    <= rst_n;
    p_en     <= enable;
    p_out    <= clk_out;
    p_clk_en <= clk_en;
    if (cnt_edge) off <= !p_en;
    if (!rst_n) off <= 1'b1;
    if (change) begin
      half   <= 3'd0;
      steady <= !(cnt_edge && !p_en) && rst_n;
      if (steady && clk_out) full_period <= 1'b1;
    end else begin
      if (tog && half != 3'd7) half <= half + 3'd1;
      if ((cnt_edge && !p_en) || !rst_n) steady <= 1'b0;
    end
    if (!rst_n || (cnt_edge && !p_en)) begin
      gap    <= '0;
      gap_ok <= 1'b0;
    end else if (cnt_edge) begin
      if (p_clk_en) begin
        gap    <= '0;
        gap_ok <= 1'b1;
      end else if (gap != 3'd7) begin
        gap <= gap + 3'd1;
      end
    end
  end

  always @(*) begin
    if (started) begin
      // No glitch
      if (change) assert (tog);
      if (D % 2 == 0 && change) assert (rise);
      if (D % 2 == 1 && clk_out && !p_out) assert (fall);
      if (D % 2 == 1 && !clk_out && p_out) assert (rise);
      // Duty
      if (steady_now && change) assert (half + 3'd1 == 3'(D));
      if (steady_now && !change) assert (half + 3'(tog) < 3'(D));
      // Enable
      if (off && !(cnt_edge && p_en)) assert (!clk_out);
      if (!enable) assert (!clk_en);
      // clk_en period
      if (cnt_edge && !cut && p_clk_en && gap_ok) assert (gap == 3'(D - 1));
      if (cnt_edge && !cut && !p_clk_en && gap_ok) assert (gap < 3'(D - 1));

      // Where the counter and phase flops stand, on quiet steps
      assert (f_count <= 2'(D - 1));
      if (rst_n && D % 2 == 0) assert (clk_out == (f_count >= 2'(D / 2)));
      if (rst_n && D % 2 == 1) begin
        if (f_rise) assert (f_count != 2'd2);
        if (!clk) assert (f_fall == f_rise);
        // After the wrap edge the falling-edge flop still holds the cleared
        // value until the clock falls; one edge later it has caught up.
        if (clk && f_rise && f_count == 2'd0) assert (!f_fall);
        if (f_rise && f_count == 2'd1) assert (f_fall);
      end
      if (!tog && rst_n) begin
        if (gap_ok) assert (3'(f_count) == gap);
        if (off) assert (f_count == 2'd0 && !clk_out && !f_rise);
        if (steady && D % 2 == 0)
          assert (half == 3'(2 * (f_count - (clk_out ? 2'(D / 2) : 2'd0))) + 3'(!clk));
        if (steady && D % 2 == 1 && clk_out)
          assert (half == 3'(2 * f_count) - 3'(clk));
        if (steady && D % 2 == 1 && !clk_out) begin
          assert (half == 3'(2 * ((f_count == 2'd2) ? 2'd0 : f_count + 2'd1)) + 3'(!clk));
          assert (f_fall == (half == 3'd0) && f_rise == (half == 3'd2));
        end
      end
    end
  end

  always @(*) begin
    if (started) cover (full_period && change && steady);
  end

  // A cover exists even when its condition is constant, so the odd-only
  // one is generated only in the odd instance.
  if (D % 2 == 1) begin : g_odd_cover
    always @(*) begin
      if (started) cover (p_out && !clk_out && cnt_edge && !p_en);
    end
  end

endmodule

`default_nettype wire
