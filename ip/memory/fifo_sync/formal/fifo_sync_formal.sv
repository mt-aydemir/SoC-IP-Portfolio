//=============================================================================
// Module      : fifo_sync_formal
// Category    : memory
// Description : Formal property wrapper for fifo_sync.
//
// Proves, at DEPTH = 5 (not a power of two) and DATA_WIDTH = 4, for every
// input sequence from reset:
//
//   ORDER    every word comes out once, in the order it went in, with none
//            lost or invented. The FIFO never looks at its data, so the
//            source is assumed to write sequence numbers - write n carries
//            n mod 16 - and m_data must equal the number of reads so far,
//            mod 16, whenever m_valid is high. Sixteen exceeds the five
//            words that can be held, so a skipped, repeated or reordered
//            word changes the value seen.
//   LEVEL    level is the number of words written and not yet read; full,
//            empty, s_ready, almost_full (level >= 4) and almost_empty
//            (level <= 1) follow from it, and m_valid is high exactly when
//            a word is at the head. Nothing is accepted while full.
//   HOLD     a word offered and not taken stays on m_data.
//
// For induction the wrapper probes the storage - the RAM words, the RAM's
// read register, the two output registers and the counters and pointers
// that say which of them hold live words - and states where each live
// word sits in the sequence. Without that, a long stall would hide stored
// words and induction could not rule out unreachable contents.
//
// Covers reach full, the write bypass into an empty FIFO, a word that went
// through the RAM, and a read and a write on the same cycle at level 3.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module fifo_sync_formal (
    input wire       clk,
    input wire       rst_n,
    input wire       s_valid,
    input wire [3:0] s_data,
    input wire       m_ready
);

  localparam int unsigned D  = 5;
  localparam int unsigned DW = 4;

  logic          s_ready, m_valid, full, empty, almost_full, almost_empty;
  logic [DW-1:0] m_data;
  logic [2:0]    level;

  fifo_sync #(.DATA_WIDTH(DW), .DEPTH(D)) dut (
      .clk(clk), .rst_n(rst_n),
      .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data),
      .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data),
      .level(level), .full(full), .empty(empty),
      .almost_full(almost_full), .almost_empty(almost_empty));

  // formal-connect: f_ram_count = dut.ram_count_q
  // formal-connect: f_inflight = dut.inflight_q
  // formal-connect: f_out_count = dut.out_count_q
  // formal-connect: f_rd_ptr = dut.rd_ptr_q
  // formal-connect: f_wr_ptr = dut.wr_ptr_q
  // formal-connect: f_out0 = dut.out_data_q[0]
  // formal-connect: f_out1 = dut.out_data_q[1]
  // formal-connect: f_rdata = dut.u_storage.read_data
  // formal-connect: f_mem0 = dut.u_storage.mem[0]
  // formal-connect: f_mem1 = dut.u_storage.mem[1]
  // formal-connect: f_mem2 = dut.u_storage.mem[2]
  // formal-connect: f_mem3 = dut.u_storage.mem[3]
  // formal-connect: f_mem4 = dut.u_storage.mem[4]
  (* keep *) wire [2:0]    f_ram_count;
  (* keep *) wire          f_inflight;
  (* keep *) wire [1:0]    f_out_count;
  (* keep *) wire [2:0]    f_rd_ptr, f_wr_ptr;
  (* keep *) wire [DW-1:0] f_out0, f_out1, f_rdata;
  (* keep *) wire [DW-1:0] f_mem0, f_mem1, f_mem2, f_mem3, f_mem4;

  logic [DW-1:0] f_mem [D];
  assign f_mem[0] = f_mem0;
  assign f_mem[1] = f_mem1;
  assign f_mem[2] = f_mem2;
  assign f_mem[3] = f_mem3;
  assign f_mem[4] = f_mem4;

  // Sequence numbers written and read, and the true occupancy.
  logic [DW-1:0] wr_seq, rd_seq;
  logic [2:0]    count;
  logic          wr, rd;

  assign wr = s_valid && s_ready;
  assign rd = m_valid && m_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_seq <= '0;
      rd_seq <= '0;
      count  <= '0;
    end else begin
      if (wr) wr_seq <= wr_seq + 1'b1;
      if (rd) rd_seq <= rd_seq + 1'b1;
      count <= count + 3'(wr) - 3'(rd);
    end
  end

  initial assume (!rst_n);
  always @(*) if (s_valid) assume (s_data == wr_seq);

  // Position of each RAM slot after the read pointer, and the sequence
  // number of the word at the read pointer.
  logic [2:0]    rel [D];
  logic [DW-1:0] ram_head;
  for (genvar j = 0; j < D; j++) begin : g_rel
    assign rel[j] = (3'(j) >= f_rd_ptr) ? 3'(j) - f_rd_ptr : 3'(j + D) - f_rd_ptr;
  end
  assign ram_head = rd_seq + DW'(f_out_count) + DW'(f_inflight);

  // Hold: what was offered and not taken.
  logic          past_stall;
  logic [DW-1:0] past_data;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      past_stall <= 1'b0;
      past_data  <= '0;
    end else begin
      past_stall <= m_valid && !m_ready;
      past_data  <= m_data;
    end
  end

  always @(*) begin
    if (rst_n) begin
      // Order
      if (m_valid) assert (m_data == rd_seq);
      // Level and flags
      assert (count <= 3'(D));
      assert (level == count);
      assert (full == (count == 3'(D)));
      assert (empty == (count == 3'd0));
      assert (s_ready == !full);
      assert (almost_full == (count >= 3'd4));
      assert (almost_empty == (count <= 3'd1));
      assert (m_valid == (f_out_count != 2'd0));
      // Hold
      if (past_stall) assert (m_valid && m_data == past_data);

      // Where every live word sits.
      assert (wr_seq == rd_seq + DW'(count));
      assert (4'(count) == 4'(f_ram_count) + 4'(f_inflight) + 4'(f_out_count));
      assert (f_out_count <= 2'd2);
      assert (f_rd_ptr < 3'(D) && f_wr_ptr < 3'(D));
      assert (3'((f_rd_ptr + f_ram_count) % D) == f_wr_ptr);
      if (f_out_count >= 2'd1) assert (f_out0 == rd_seq);
      if (f_out_count == 2'd2) assert (f_out1 == rd_seq + 4'd1);
      if (f_inflight) assert (f_rdata == rd_seq + DW'(f_out_count));
      if (f_inflight) assert (f_out_count + 2'(f_inflight) <= 2'd2);
      for (int j = 0; j < D; j++) begin
        if (rel[j] < f_ram_count) assert (f_mem[j] == ram_head + DW'(rel[j]));
      end
    end
  end

  // Non-vacuity.
  logic past_bypass;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) past_bypass <= 1'b0;
    else        past_bypass <= wr && count == 3'd0;
  end

  always @(*) begin
    if (rst_n) begin
      cover (full);
      cover (past_bypass && m_valid);
      cover (f_inflight && f_ram_count != 3'd0);
      cover (wr && rd && count == 3'd3);
    end
  end

endmodule

`default_nettype wire
