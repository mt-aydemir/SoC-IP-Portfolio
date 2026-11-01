//=============================================================================
// Module      : cdc_pulse_sync_formal
// Category    : cdc
// Description : Formal property wrapper for cdc_pulse_sync.
//
// Proved with free-running clocks (FORMAL_MULTICLOCK): both clocks, both
// resets and src_pulse are free inputs that may change on any solver step,
// so every ratio and phase between the clocks is explored, including edges
// on the same step. Each reset is low at the start and released once, in
// either order, at any time - one reset per domain, as the header says.
// For every such sequence:
//
//   ONE FOR ONE  every accepted source pulse - src_pulse high while
//                src_busy is low, at a source edge - produces exactly one
//                destination pulse, and no destination pulse appears
//                without one; at most one event is in flight
//   BUSY         src_busy is high whenever an event is in flight
//   WIDTH        a destination pulse lasts exactly one destination cycle
//
// For induction the six flops of the toggle loop - the source toggle, two
// destination synchroniser stages, the destination register, two
// acknowledge stages - are probed: the loop never holds more than one
// boundary between old and new toggle values, which is what makes the toggle
// handshake safe, and the toggles' parities match the event counts.
//
// Covers: two events delivered, a pulse ignored because the block was busy,
// and a destination pulse raised while the source clock is held low.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module cdc_pulse_sync_formal (
    input wire src_clk,
    input wire src_rst_n,
    input wire src_pulse,
    input wire dst_clk,
    input wire dst_rst_n
);

  (* gclk *) reg gclk;

  logic src_busy, dst_pulse;

  cdc_pulse_sync #(.STAGES(2)) dut (
      .src_clk(src_clk), .src_rst_n(src_rst_n), .src_pulse(src_pulse), .src_busy(src_busy),
      .dst_clk(dst_clk), .dst_rst_n(dst_rst_n), .dst_pulse(dst_pulse));

  // formal-connect: f_toggle = dut.src_toggle_q
  // formal-connect: f_d0 = dut.u_sync_to_dst.sync_q[0]
  // formal-connect: f_d1 = dut.u_sync_to_dst.sync_q[1]
  // formal-connect: f_dq = dut.dst_toggle_q
  // formal-connect: f_a0 = dut.u_sync_to_src.sync_q[0]
  // formal-connect: f_a1 = dut.u_sync_to_src.sync_q[1]
  (* keep *) wire f_toggle, f_d0, f_d1, f_dq, f_a0, f_a1;

  logic       p_src_clk = 1'b0, p_dst_clk = 1'b0, p_src_rst = 1'b0, p_dst_rst = 1'b0;
  logic       p_pulse = 1'b0, p_busy = 1'b0, p_dst_pulse = 1'b0;
  logic [2:0] n_acc = '0, n_dst = '0;
  logic       ignored = 1'b0;
  logic       src_edge, dst_edge, accept;
  logic [2:0] acc_now, dst_now;      // the counts including this step
  logic [2:0] delivered;             // pulses raised, the one now high included

  // An edge samples the previous step, and does nothing on the step its
  // reset is released.
  assign src_edge = src_clk && !p_src_clk && p_src_rst && src_rst_n;
  assign dst_edge = dst_clk && !p_dst_clk && p_dst_rst && dst_rst_n;
  assign accept   = src_edge && p_pulse && !p_busy;
  assign acc_now  = n_acc + 3'(accept);
  assign dst_now  = n_dst + 3'(dst_edge && p_dst_pulse);
  assign delivered = dst_now + 3'(dst_pulse);

  always @(posedge gclk) begin
    p_src_clk   <= src_clk;
    p_dst_clk   <= dst_clk;
    p_src_rst   <= src_rst_n;
    p_dst_rst   <= dst_rst_n;
    p_pulse     <= src_pulse;
    p_busy      <= src_busy;
    p_dst_pulse <= dst_pulse;
    n_acc <= acc_now;
    n_dst <= dst_now;
    if (src_edge && p_pulse && p_busy) ignored <= 1'b1;
  end

  initial assume (!src_rst_n && !dst_rst_n);
  always @(*) begin
    if (p_src_rst) assume (src_rst_n);
    if (p_dst_rst) assume (dst_rst_n);
  end

  logic [5:0] loop;
  logic [4:0] boundaries;
  assign loop       = {f_toggle, f_d0, f_d1, f_dq, f_a0, f_a1};
  assign boundaries = loop[5:1] ^ loop[4:0];

  always @(*) begin
    // One for one, and one in flight at most
    assert (acc_now - delivered <= 3'd1);
    // Busy while in flight
    if (acc_now != delivered) assert (src_busy);
    // Width: a pulse is gone after one destination edge
    if (dst_edge && p_dst_pulse) assert (!dst_pulse);
    // The loop
    assert ((boundaries & (boundaries - 5'd1)) == 5'd0);
    assert (src_busy == (f_toggle ^ f_a1));
    assert (acc_now[0] == f_toggle);
    assert (delivered[0] == f_dq);
    // A pulse is raised by the edge that moved the new toggle into the
    // destination register; no destination edge has happened since.
    if (dst_pulse) assert (f_d0 == f_dq && f_d1 == f_dq);
  end

  always @(*) begin
    cover (n_dst == 3'd2);
    cover (ignored && n_dst == 3'd1);
    cover (dst_pulse && !src_clk && !p_src_clk && n_acc == 3'd1);
  end

endmodule

`default_nettype wire
