//=============================================================================
// Module      : cdc_handshake_formal
// Category    : cdc
// Description : Formal property wrapper for cdc_handshake.
//
// Proved with free-running clocks (FORMAL_MULTICLOCK): both clocks, both
// resets, src_valid and dst_ready are free inputs that may change on any
// solver step, so every ratio and phase between the clocks is explored.
// Each reset is low at the start and released once, in either order, at
// any time. The source offers word n as n mod 16. For every such sequence:
//
//   ORDER     every accepted word is presented on the destination side once,
//             in order and intact - dst_data equals the number of words
//             already delivered whenever dst_valid is high - and nothing is
//             presented that was not sent; at most one word is in flight
//   HOLD      a presented word stays, unchanged, until dst_ready takes it
//   SAFE      the payload register the destination samples across the
//             domain boundary never changes while a request is pending, so
//             no bit can be caught mid-change
//
// For induction the probes cover both state machines, the request and
// acknowledge registers and both synchronisers. The six signals of the
// four-phase loop - req, its two synchroniser stages, ack, its two stages -
// form a rotating thermometer code with at most one boundary, and each
// state of each machine pins down part of it.
//
// Covers: two words delivered, a word held under dst_ready low, and the
// source offering a word while the previous one is still recovering.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module cdc_handshake_formal (
    input wire src_clk,
    input wire src_rst_n,
    input wire src_valid,
    input wire dst_clk,
    input wire dst_rst_n,
    input wire dst_ready
);

  (* gclk *) reg gclk;

  logic       src_ready, dst_valid;
  logic [3:0] dst_data;
  logic [3:0] n_src = '0, n_dst = '0;

  cdc_handshake #(.DATA_WIDTH(4), .STAGES(2)) dut (
      .src_clk(src_clk), .src_rst_n(src_rst_n),
      .src_valid(src_valid), .src_ready(src_ready), .src_data(n_src),
      .dst_clk(dst_clk), .dst_rst_n(dst_rst_n),
      .dst_valid(dst_valid), .dst_ready(dst_ready), .dst_data(dst_data));

  // formal-connect: f_src_state = dut.src_state_q
  // formal-connect: f_req = dut.src_req_q
  // formal-connect: f_payload = dut.payload_q
  // formal-connect: f_r0 = dut.u_sync_req.sync_q[0]
  // formal-connect: f_r1 = dut.u_sync_req.sync_q[1]
  // formal-connect: f_dst_state = dut.dst_state_q
  // formal-connect: f_ack = dut.dst_ack_q
  // formal-connect: f_a0 = dut.u_sync_ack.sync_q[0]
  // formal-connect: f_a1 = dut.u_sync_ack.sync_q[1]
  (* keep *) wire [1:0] f_src_state, f_dst_state;
  (* keep *) wire       f_req, f_r0, f_r1, f_ack, f_a0, f_a1;
  (* keep *) wire [3:0] f_payload;

  localparam logic [1:0] SRC_IDLE = 2'd0, SRC_REQUEST = 2'd1, SRC_RECOVER = 2'd2;
  localparam logic [1:0] DST_IDLE = 2'd0, DST_PRESENT = 2'd1, DST_ACK = 2'd2;

  logic       p_src_clk = 1'b0, p_dst_clk = 1'b0, p_src_rst = 1'b0, p_dst_rst = 1'b0;
  logic       p_valid = 1'b0, p_ready_src = 1'b0, p_dst_valid = 1'b0, p_dst_ready = 1'b0;
  logic [3:0] p_dst_data = '0, p_payload = '0;
  logic       p_pending = 1'b0;
  logic       src_edge, dst_edge, take, deliver;
  logic [3:0] src_now, dst_now;

  assign src_edge = src_clk && !p_src_clk && p_src_rst && src_rst_n;
  assign dst_edge = dst_clk && !p_dst_clk && p_dst_rst && dst_rst_n;
  assign take     = src_edge && p_valid && p_ready_src;
  assign deliver  = dst_edge && p_dst_valid && p_dst_ready;
  assign src_now  = n_src + 4'(take);
  assign dst_now  = n_dst + 4'(deliver);

  always @(posedge gclk) begin
    p_src_clk   <= src_clk;
    p_dst_clk   <= dst_clk;
    p_src_rst   <= src_rst_n;
    p_dst_rst   <= dst_rst_n;
    p_valid     <= src_valid;
    p_ready_src <= src_ready;
    p_dst_valid <= dst_valid;
    p_dst_ready <= dst_ready;
    p_dst_data  <= dst_data;
    p_payload   <= f_payload;
    p_pending   <= f_req && !f_ack;
    n_src       <= src_now;
    n_dst       <= dst_now;
  end

  initial assume (!src_rst_n && !dst_rst_n);
  always @(*) begin
    if (p_src_rst) assume (src_rst_n);
    if (p_dst_rst) assume (dst_rst_n);
  end

  logic [5:0] loop;
  logic [4:0] boundaries;
  assign loop       = {f_req, f_r0, f_r1, f_ack, f_a0, f_a1};
  assign boundaries = loop[5:1] ^ loop[4:0];

  always @(*) begin
    // Order
    assert (src_now - dst_now <= 4'd1);
    assert ((src_now != dst_now) == (f_req && !f_ack));
    if (dst_valid) assert (dst_data == dst_now && src_now != dst_now);
    // Hold
    if (p_dst_valid && !deliver) assert (dst_valid && dst_data == p_dst_data);
    // Safe: the payload holds while a request is pending
    if (p_pending && f_req) assert (f_payload == p_payload);
    if (f_src_state != SRC_IDLE) assert (f_payload == src_now - 4'd1);

    // The loop and the state machines
    assert ((boundaries & (boundaries - 5'd1)) == 5'd0);
    assert (f_src_state != 2'd3 && f_dst_state != 2'd3);
    assert (src_ready == (f_src_state == SRC_IDLE));
    if (f_src_state == SRC_IDLE)    assert (loop == 6'b000000);
    if (f_src_state == SRC_REQUEST) assert (f_req);
    if (f_src_state == SRC_RECOVER) assert (!f_req);
    assert (dst_valid == (f_dst_state == DST_PRESENT));
    if (f_dst_state == DST_IDLE)    assert (!f_ack);
    if (f_dst_state == DST_PRESENT) assert (loop == 6'b111000);
    if (f_dst_state == DST_ACK)     assert (f_ack);
  end

  logic held = 1'b0, early = 1'b0;
  always @(posedge gclk) begin
    if (p_dst_valid && !p_dst_ready && dst_edge) held <= 1'b1;
    if (src_valid && f_src_state == SRC_RECOVER) early <= 1'b1;
  end

  always @(*) begin
    cover (dst_now == 4'd2);
    cover (held && dst_now == 4'd1);
    cover (early && dst_now == 4'd1);
  end

endmodule

`default_nettype wire
