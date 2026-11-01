//=============================================================================
// Module      : axi4_stream_slice_formal
// Category    : bus
// Description : Formal property wrapper for axi4_stream_slice, all five
//               modes at once.
//
// Each mode gets its own instance and its own source and sink, so that the
// handshakes of one cannot mask another's. For every input sequence from
// reset, in every mode:
//
//   ORDER     the source sends beat n with a payload computed from n mod 256
//             - TDATA is n, and TSTRB, TKEEP, TLAST, TID, TDEST and TUSER are
//             six of its bits - so every beat must leave once, in order,
//             with all its sidebands, whenever TVALID is high on the output
//   HOLD      an output beat that is not taken stays, payload and all
//             (AXI4-Stream's rule for a source), given that the slice's own
//             source obeys the same rule - which is assumed
//   CAPACITY  beats held never exceed the mode's storage: none in BYPASS,
//             one in FORWARD, REVERSE and LIGHT, two in FULL
//   READY     the documented timing of each mode: BYPASS passes TVALID and
//             TREADY straight through; FORWARD has TVALID registered and
//             accepts when empty or draining; REVERSE has TREADY registered;
//             FULL registers both and accepts whenever fewer than two beats
//             are held; LIGHT alternates, holding one beat at a time
//
// FULL's skid register holds a beat the output does not show; it is probed
// for induction, as is its flag.
//
// Covers, in every mode: a beat leaves, an output stall is held for two
// cycles, and - except BYPASS - the slice is full while the sink stalls.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module axi4_stream_slice_formal (
    input wire       clk,
    input wire       rst_n,
    input wire [4:0] s_valid,
    input wire [4:0] m_ready
);

  // Yosys names the branches of an if / else-if generate chain as nested
  // genblk1 scopes, the fourth branch three levels down.
  // formal-connect: f_full_skid = u_full.dut.genblk1.genblk1.genblk1.g_full.skid_data
  // formal-connect: f_full_skid_q = u_full.dut.genblk1.genblk1.genblk1.g_full.skid_q
  (* keep *) wire [13:0] f_full_skid;
  (* keep *) wire        f_full_skid_q;

  initial assume (!rst_n);

  axi4_stream_slice_check #(.MODE(0)) u_bypass (
      .clk(clk), .rst_n(rst_n), .s_valid(s_valid[0]), .m_ready(m_ready[0]),
      .f_skid('0), .f_skid_q(1'b0));
  axi4_stream_slice_check #(.MODE(1)) u_forward (
      .clk(clk), .rst_n(rst_n), .s_valid(s_valid[1]), .m_ready(m_ready[1]),
      .f_skid('0), .f_skid_q(1'b0));
  axi4_stream_slice_check #(.MODE(2)) u_reverse (
      .clk(clk), .rst_n(rst_n), .s_valid(s_valid[2]), .m_ready(m_ready[2]),
      .f_skid('0), .f_skid_q(1'b0));
  axi4_stream_slice_check #(.MODE(3)) u_full (
      .clk(clk), .rst_n(rst_n), .s_valid(s_valid[3]), .m_ready(m_ready[3]),
      .f_skid(f_full_skid), .f_skid_q(f_full_skid_q));
  axi4_stream_slice_check #(.MODE(4)) u_light (
      .clk(clk), .rst_n(rst_n), .s_valid(s_valid[4]), .m_ready(m_ready[4]),
      .f_skid('0), .f_skid_q(1'b0));

endmodule

// One mode: the instance, its source and sink, and the properties.
module axi4_stream_slice_check #(
    parameter int unsigned MODE = 0
) (
    input wire        clk,
    input wire        rst_n,
    input wire        s_valid,
    input wire        m_ready,
    input wire [13:0] f_skid,      // FULL only: the skid register and its flag
    input wire        f_skid_q
);

  localparam int unsigned CAPACITY = (MODE == 0) ? 0 : (MODE == 3) ? 2 : 1;

  // The payload of beat n, as {TDATA, TSTRB, TKEEP, TLAST, TID, TDEST, TUSER}.
  function automatic logic [13:0] beat(input logic [7:0] n);
    beat = {n, n[7:2]};
  endfunction

  logic [7:0]  wr_seq, rd_seq;
  logic [1:0]  count;
  logic        s_ready, m_valid;
  logic [13:0] m_payload;
  logic [13:0] s_payload;

  assign s_payload = beat(wr_seq);

  axi4_stream_slice #(
      .MODE(MODE), .DATA_WIDTH(8), .ID_WIDTH(1), .DEST_WIDTH(1), .USER_WIDTH(1)
  ) dut (
      .clk(clk), .rst_n(rst_n),
      .s_axis_tvalid(s_valid), .s_axis_tready(s_ready),
      .s_axis_tdata(s_payload[13:6]), .s_axis_tstrb(s_payload[5]),
      .s_axis_tkeep(s_payload[4]), .s_axis_tlast(s_payload[3]),
      .s_axis_tid(s_payload[2]), .s_axis_tdest(s_payload[1]), .s_axis_tuser(s_payload[0]),
      .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
      .m_axis_tdata(m_payload[13:6]), .m_axis_tstrb(m_payload[5]),
      .m_axis_tkeep(m_payload[4]), .m_axis_tlast(m_payload[3]),
      .m_axis_tid(m_payload[2]), .m_axis_tdest(m_payload[1]), .m_axis_tuser(m_payload[0]));

  logic wr, rd;
  assign wr = s_valid && s_ready;
  assign rd = m_valid && m_ready;

  logic        past_s_stall, past_m_stall;
  logic [13:0] past_m_payload;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_seq         <= '0;
      rd_seq         <= '0;
      count          <= '0;
      past_s_stall   <= 1'b0;
      past_m_stall   <= 1'b0;
      past_m_payload <= '0;
    end else begin
      if (wr) wr_seq <= wr_seq + 8'd1;
      if (rd) rd_seq <= rd_seq + 8'd1;
      count          <= count + 2'(wr) - 2'(rd);
      past_s_stall   <= s_valid && !s_ready;
      past_m_stall   <= m_valid && !m_ready;
      past_m_payload <= m_payload;
    end
  end

  // The source obeys AXI4-Stream: a beat offered stays offered until taken.
  // Its payload depends only on wr_seq, so it cannot change either.
  always @(*) if (rst_n && past_s_stall) assume (s_valid);

  always @(*) begin
    if (rst_n) begin
      assert (wr_seq == rd_seq + 8'(count));
      assert (count <= 2'(CAPACITY));
      if (m_valid) assert (m_payload == beat(rd_seq));
      if (past_m_stall) assert (m_valid && m_payload == past_m_payload);

      unique case (MODE)
        0: assert (m_valid == s_valid && s_ready == m_ready);
        1: assert (m_valid == (count == 2'd1) && s_ready == (count == 2'd0 || m_ready));
        2: assert (s_ready == (count == 2'd0) && m_valid == (count == 2'd1 || s_valid));
        3: begin
          assert (s_ready == (count < 2'd2) && m_valid == (count != 2'd0));
          assert (f_skid_q == (count == 2'd2));
          if (f_skid_q) assert (f_skid == beat(rd_seq + 8'd1));
        end
        default: assert (s_ready == (count == 2'd0) && m_valid == (count == 2'd1));
      endcase
    end
  end

  always @(*) begin
    if (rst_n) begin
      cover (rd);
      cover (past_m_stall && m_valid && !m_ready);
      if (MODE != 0) cover (count == 2'(CAPACITY) && !m_ready);
    end
  end

endmodule

`default_nettype wire
