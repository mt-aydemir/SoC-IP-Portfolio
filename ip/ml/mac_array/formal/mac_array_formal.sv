//=============================================================================
// Module      : mac_array_formal
// Category    : ml
// Description : Formal property wrapper for mac_array.
//
// A complete equivalence proof at LANES = 2, DATA_WIDTH = 3, unsigned a
// against signed b, and the narrowest legal accumulator, 8 bits. For every
// input sequence from reset - any operands, any vector lengths, any
// back-pressure - every result is the dot product of its vector modulo
// 2**8, in order, none lost or invented, and:
//
//   FLOW      s_ready is high exactly while fewer than DEPTH = 4 results
//             are owed (accepted last beats whose results are not taken),
//             the output FIFO never overflows, m_valid is high exactly while
//             a result waits, and a waiting result holds
//   LATENCY   a result reaches the output head LATENCY = 3 cycles after its
//             last beat is accepted
//
// The reference is a model of the header's pipeline: each beat's exact sum
// a0*b0 + a1*b1, computed here from the operands with no shared code, is
// delayed through the two pipeline stages, accumulated as the header
// defines - restarting after a last beat - and queued on the last beat.
// Every pipeline register, the accumulator and the FIFO are probed and
// related to the model, which is what makes the proof inductive.
//
// Covers: a three-beat vector's result, four single-beat vectors on four
// consecutive cycles, every credit taken with the sink stalled, and a
// result held for two cycles.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module mac_array_formal (
    input wire       clk,
    input wire       rst_n,
    input wire       s_valid,
    input wire [5:0] s_a,
    input wire [5:0] s_b,
    input wire       s_last,
    input wire       m_ready
);

  localparam int unsigned DEPTH = 4;

  logic       s_ready, m_valid;
  logic [7:0] m_data;

  mac_array #(.LANES(2), .DATA_WIDTH(3), .ACC_WIDTH(8), .A_SIGNED(0), .B_SIGNED(1)) dut (
      .clk(clk), .rst_n(rst_n),
      .s_valid(s_valid), .s_ready(s_ready), .s_a(s_a), .s_b(s_b), .s_last(s_last),
      .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data));

  // formal-connect: f_prod0 = dut.prod[0]
  // formal-connect: f_prod1 = dut.prod[1]
  // formal-connect: f_node = dut.node[2]
  // formal-connect: f_v0 = dut.v_q[0]
  // formal-connect: f_v1 = dut.v_q[1]
  // formal-connect: f_l0 = dut.l_q[0]
  // formal-connect: f_l1 = dut.l_q[1]
  // formal-connect: f_acc = dut.acc
  // formal-connect: f_in_vector = dut.in_vector
  // formal-connect: f_credits = dut.credits
  // formal-connect: f_count = dut.count
  // formal-connect: f_rd_ptr = dut.rd_ptr
  // formal-connect: f_wr_ptr = dut.wr_ptr
  // formal-connect: f_fifo0 = dut.fifo[0]
  // formal-connect: f_fifo1 = dut.fifo[1]
  // formal-connect: f_fifo2 = dut.fifo[2]
  // formal-connect: f_fifo3 = dut.fifo[3]
  (* keep *) wire [6:0] f_prod0, f_prod1;
  (* keep *) wire [7:0] f_node, f_acc;
  (* keep *) wire       f_v0, f_v1, f_l0, f_l1, f_in_vector;
  (* keep *) wire [2:0] f_credits, f_count;
  (* keep *) wire [1:0] f_rd_ptr, f_wr_ptr;
  (* keep *) wire [7:0] f_fifo0, f_fifo1, f_fifo2, f_fifo3;

  logic [7:0] f_fifo [DEPTH];
  assign f_fifo[0] = f_fifo0;
  assign f_fifo[1] = f_fifo1;
  assign f_fifo[2] = f_fifo2;
  assign f_fifo[3] = f_fifo3;

  // The exact sum of the beat on the input: a unsigned, b signed.
  function automatic logic signed [7:0] beat_sum(input logic [5:0] a, input logic [5:0] b);
    beat_sum = 8'($signed({5'b0, a[2:0]}) * $signed({{5{b[2]}}, b[2:0]})
                + $signed({5'b0, a[5:3]}) * $signed({{5{b[5]}}, b[5:3]}));
  endfunction

  logic       take, pop;
  assign take = s_valid && s_ready;
  assign pop  = m_valid && m_ready;

  // Model: two pipeline stages, the accumulator, the result queue.
  logic [7:0] s1_sum, s2_sum, m_acc, total;
  logic       s1_v, s1_l, s2_v, s2_l, m_in;
  logic [7:0] q [DEPTH];
  logic [2:0] qn;

  assign total = (m_in ? m_acc : 8'h00) + s2_sum;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      {s1_sum, s2_sum, m_acc} <= '0;
      {s1_v, s1_l, s2_v, s2_l, m_in} <= '0;
      for (int k = 0; k < DEPTH; k++) q[k] <= '0;
      qn <= '0;
    end else begin
      s1_sum <= beat_sum(s_a, s_b);
      s1_v   <= take;
      s1_l   <= s_last;
      s2_sum <= s1_sum;
      s2_v   <= s1_v;
      s2_l   <= s1_l;
      if (s2_v) begin
        m_acc <= total;
        m_in  <= !s2_l;
      end
      // Queue: pop from the front, push at the back.
      begin
        logic [7:0] nq [DEPTH];
        logic [2:0] n;
        for (int k = 0; k < DEPTH; k++) nq[k] = q[k];
        n = qn;
        if (pop) begin
          for (int k = 0; k < DEPTH - 1; k++) nq[k] = nq[k + 1];
          n = n - 3'd1;
        end
        if (s2_v && s2_l) begin
          nq[n[1:0]] = total;
          n = n + 3'd1;
        end
        for (int k = 0; k < DEPTH; k++) q[k] <= nq[k];
        qn <= n;
      end
    end
  end

  logic [2:0] owed;
  assign owed = 3'(s1_v && s1_l) + 3'(s2_v && s2_l) + qn;

  // Position of each FIFO slot after the read pointer (DEPTH is 4).
  logic [1:0] rel [DEPTH];
  for (genvar j = 0; j < DEPTH; j++) begin : g_rel
    assign rel[j] = 2'(j) - f_rd_ptr;
  end

  logic       past_stall;
  logic [7:0] past_data;
  logic [3:0] lasts;        // single-beat vectors on consecutive cycles
  logic [1:0] beats;        // beats of the vector in progress, saturating

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      past_stall <= 1'b0;
      past_data  <= '0;
      lasts      <= '0;
      beats      <= '0;
    end else begin
      past_stall <= m_valid && !m_ready;
      past_data  <= m_data;
      lasts      <= {lasts[2:0], take && s_last && beats == 2'd0};
      if (take) beats <= s_last ? 2'd0 : (beats == 2'd3 ? 2'd3 : beats + 2'd1);
    end
  end

  initial assume (!rst_n);

  always @(*) begin
    if (rst_n) begin
      // Results and flow
      assert (qn <= 3'(DEPTH) && owed <= 3'(DEPTH));
      assert (f_credits == owed);
      assert (s_ready == (owed < 3'(DEPTH)));
      assert (m_valid == (qn != 3'd0));
      if (m_valid) assert (m_data == q[0]);
      if (past_stall) assert (m_valid && m_data == past_data);

      // The pipeline, the accumulator and the FIFO against the model
      assert (8'($signed(f_prod0)) + 8'($signed(f_prod1)) == s1_sum);
      assert (f_node == s2_sum);
      assert (f_v0 == s1_v && f_v1 == s2_v);
      if (s1_v) assert (f_l0 == s1_l);
      if (s2_v) assert (f_l1 == s2_l);
      assert (f_in_vector == m_in);
      if (m_in) assert (f_acc == m_acc);
      assert (f_count == qn);
      assert (f_wr_ptr == f_rd_ptr + qn[1:0]);
      for (int j = 0; j < DEPTH; j++) begin
        if (3'(rel[j]) < qn) assert (f_fifo[j] == q[rel[j]]);
      end
    end
  end

  always @(*) begin
    if (rst_n) begin
      cover (s2_v && s2_l && beats == 2'd0 && m_in && f_acc != 8'h00);
      cover (lasts == 4'b1111);
      cover (!s_ready && !m_ready);
      cover (past_stall && m_valid && !m_ready);
    end
  end

endmodule

`default_nettype wire
