//=============================================================================
// Module      : cdc_sync_2ff_formal
// Category    : cdc
// Description : Formal property wrapper for cdc_sync_2ff.
//
// Proved with free-running clocks (FORMAL_MULTICLOCK): the clock and the
// asynchronous input are free inputs that may change on any solver step,
// so the input changes at every possible position relative to the clock
// edges - before an edge, after it, or with it. A flop sampling a changing
// input therefore takes the old value on some paths and the new one on
// others, which is the outcome a synchroniser relies on metastability to
// resolve to; resolution taking longer than one stage is the design
// assumption every synchroniser makes and is not modelled.
//
// Two instances: one bit through two stages, and two bits through three
// stages with a non-zero reset value. For every input sequence, including
// resets at any time:
//
//   RESET     while rst_n is low, q_sync is the reset value - at once, not at
//             the next edge
//   EDGES     q_sync changes only on a rising clock edge or a reset
//   LATENCY   once the input has been stable across STAGES rising edges with
//             no reset, q_sync equals it
//
// Covers: each instance passes a change through, and the two-bit instance
// shows a value it was given.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module cdc_sync_2ff_formal (
    input wire       clk,
    input wire       rst_n,
    input wire       d1,
    input wire [1:0] d2
);

  (* gclk *) reg gclk;

  logic       q1;
  logic [1:0] q2;

  cdc_sync_2ff #(.WIDTH(1), .STAGES(2), .RESET_VALUE(1'b0)) dut1 (
      .clk(clk), .rst_n(rst_n), .d_async(d1), .q_sync(q1));
  cdc_sync_2ff #(.WIDTH(2), .STAGES(3), .RESET_VALUE(2'b10)) dut2 (
      .clk(clk), .rst_n(rst_n), .d_async(d2), .q_sync(q2));

  // The stages before each output, for induction.
  // formal-connect: f_t0 = dut1.sync_q[0]
  // formal-connect: f_s0 = dut2.sync_q[0]
  // formal-connect: f_s1 = dut2.sync_q[1]
  (* keep *) wire       f_t0;
  (* keep *) wire [1:0] f_s0, f_s1;

  // The previous solver step.
  logic       p_clk = 1'b0, p_rst_n = 1'b0, p_q1 = 1'b0, p_d1 = 1'b0;
  logic [1:0] p_q2 = 2'b10, p_d2 = 2'b00;
  logic [1:0] stable1 = '0, stable2 = '0;   // rising edges since the input last changed
  logic       started = 1'b0;

  logic rise;
  assign rise = clk && !p_clk;

  always @(posedge gclk) begin
    started <= 1'b1;
    p_clk   <= clk;
    p_rst_n <= rst_n;
    p_q1    <= q1;
    p_q2    <= q2;
    p_d1    <= d1;
    p_d2    <= d2;
    // An edge samples the previous step: on the step where the input changes
    // it takes the old value, and on the step reset is released it captures
    // nothing.
    if (!rst_n || d1 != p_d1)  stable1 <= '0;
    else if (rise && p_rst_n && stable1 != 2'd3) stable1 <= stable1 + 2'd1;
    if (!rst_n || d2 != p_d2)  stable2 <= '0;
    else if (rise && p_rst_n && stable2 != 2'd3) stable2 <= stable2 + 2'd1;
  end

  initial assume (!rst_n);

  always @(*) begin
    if (!rst_n) begin
      assert (q1 == 1'b0);
      assert (q2 == 2'b10);
    end
    if (started && rst_n && p_rst_n && !rise) begin
      assert (q1 == p_q1);
      assert (q2 == p_q2);
    end
    if (rst_n && stable1 >= 2'd2 && d1 == p_d1) assert (q1 == d1);
    if (rst_n && stable2 >= 2'd3 && d2 == p_d2) assert (q2 == d2);
    if (rst_n && stable1 >= 2'd1 && d1 == p_d1) assert (f_t0 == d1);
    if (rst_n && stable2 >= 2'd1 && d2 == p_d2) assert (f_s0 == d2);
    if (rst_n && stable2 >= 2'd2 && d2 == p_d2) assert (f_s1 == d2);
  end

  always @(*) begin
    if (started && rst_n) begin
      cover (q1 && !p_q1);
      cover (q2 == 2'b01 && p_q2 != 2'b01);
    end
  end

endmodule

`default_nettype wire
