//=============================================================================
// Testbench   : tb_axi4_stream_slice
// Description : Self-checking SystemVerilog testbench for axi4_stream_slice.
//
// The Python-free smoke test, and the one place all five modes run: one
// instance per MODE, side by side, each with its own source and sink. A beat's
// payload - every sideband included - is a function of its index, so each
// sink checks order and content without a queue. Phase 0 runs with random
// source gaps and sink back-pressure; phase 1 runs every source and sink at
// full rate and checks each mode's throughput and latency. The full suite
// lives in cocotb/test_axi4_stream_slice.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_axi4_stream_slice;

  localparam int unsigned MODES      = 5;
  localparam int unsigned DATA_WIDTH = 32;
  localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8;
  localparam int unsigned ID_WIDTH   = 4;
  localparam int unsigned DEST_WIDTH = 4;
  localparam int unsigned USER_WIDTH = 2;
  localparam int unsigned WIDTH      = DATA_WIDTH + 2 * STRB_WIDTH + 1
                                     + ID_WIDTH + DEST_WIDTH + USER_WIDTH;
  localparam int unsigned N_RANDOM   = 4000;
  localparam int unsigned N_RATE     = 500;
  localparam time         CLK_PERIOD = 10ns;

  logic clk;
  logic rst_n;
  logic phase;              // 0: random flow, 1: full rate
  int unsigned cycle = 0;
  int unsigned phase_start;

  logic [MODES-1:0]            s_valid, s_ready, m_valid, m_ready;
  logic [MODES-1:0][WIDTH-1:0] s_payload, m_payload;
  int unsigned                 sent [MODES];
  int unsigned                 recv [MODES];
  int unsigned                 done_cycle [MODES];

  int unsigned error_count;
  int unsigned check_count;

  // Every field of beat i, derived from i alone.
  function automatic logic [WIDTH-1:0] beat(input int unsigned i);
    logic [DATA_WIDTH-1:0] data = DATA_WIDTH'(i * 32'h9E3779B9) ^ DATA_WIDTH'(i << 7);
    logic [STRB_WIDTH-1:0] strb = STRB_WIDTH'(i * 3);
    logic [STRB_WIDTH-1:0] keep = STRB_WIDTH'((i * 5) >> 1);
    logic                  last = i[0] ^ i[3];
    logic [ID_WIDTH-1:0]   id   = ID_WIDTH'(i >> 2);
    logic [DEST_WIDTH-1:0] dest = DEST_WIDTH'(i * 7);
    logic [USER_WIDTH-1:0] user = USER_WIDTH'(i >> 5);
    return {data, strb, keep, last, id, dest, user};
  endfunction

  function automatic int unsigned limit();
    return phase ? N_RANDOM + N_RATE : N_RANDOM;
  endfunction

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  always_ff @(posedge clk) cycle <= cycle + 1;

  for (genvar m = 0; m < MODES; m++) begin : g_mode
    axi4_stream_slice #(
        .MODE       (m),
        .DATA_WIDTH (DATA_WIDTH),
        .ID_WIDTH   (ID_WIDTH),
        .DEST_WIDTH (DEST_WIDTH),
        .USER_WIDTH (USER_WIDTH)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_axis_tvalid (s_valid[m]),
        .s_axis_tready (s_ready[m]),
        .s_axis_tdata  (s_payload[m][WIDTH-1 -: DATA_WIDTH]),
        .s_axis_tstrb  (s_payload[m][WIDTH-DATA_WIDTH-1 -: STRB_WIDTH]),
        .s_axis_tkeep  (s_payload[m][WIDTH-DATA_WIDTH-STRB_WIDTH-1 -: STRB_WIDTH]),
        .s_axis_tlast  (s_payload[m][ID_WIDTH+DEST_WIDTH+USER_WIDTH]),
        .s_axis_tid    (s_payload[m][DEST_WIDTH+USER_WIDTH +: ID_WIDTH]),
        .s_axis_tdest  (s_payload[m][USER_WIDTH +: DEST_WIDTH]),
        .s_axis_tuser  (s_payload[m][0 +: USER_WIDTH]),
        .m_axis_tvalid (m_valid[m]),
        .m_axis_tready (m_ready[m]),
        .m_axis_tdata  (m_payload[m][WIDTH-1 -: DATA_WIDTH]),
        .m_axis_tstrb  (m_payload[m][WIDTH-DATA_WIDTH-1 -: STRB_WIDTH]),
        .m_axis_tkeep  (m_payload[m][WIDTH-DATA_WIDTH-STRB_WIDTH-1 -: STRB_WIDTH]),
        .m_axis_tlast  (m_payload[m][ID_WIDTH+DEST_WIDTH+USER_WIDTH]),
        .m_axis_tid    (m_payload[m][DEST_WIDTH+USER_WIDTH +: ID_WIDTH]),
        .m_axis_tdest  (m_payload[m][USER_WIDTH +: DEST_WIDTH]),
        .m_axis_tuser  (m_payload[m][0 +: USER_WIDTH])
    );

    // The source offers beat sent[m]; a beat on offer stays until taken.
    assign s_payload[m] = beat(sent[m]);
  end

  // Sources and sinks for every mode, registered like any synchronous logic,
  // so the slice sees inputs that change only on edges.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int m = 0; m < MODES; m++) begin
        s_valid[m]    <= 1'b0;
        m_ready[m]    <= 1'b0;
        sent[m]       <= 0;
        recv[m]       <= 0;
        done_cycle[m] <= 0;
      end
    end else begin
      for (int m = 0; m < MODES; m++) begin
        automatic int unsigned next_sent = sent[m] + 32'(s_valid[m] && s_ready[m]);
        sent[m] <= next_sent;
        if (s_valid[m] && !s_ready[m]) begin
          s_valid[m] <= 1'b1;
        end else begin
          s_valid[m] <= (next_sent < limit()) && (phase || $urandom_range(0, 2) != 0);
        end
        m_ready[m] <= phase || ($urandom_range(0, 2) != 0);

        if (m_valid[m] && m_ready[m]) begin
          check_count++;
          if (m_payload[m] !== beat(recv[m])) begin
            error_count++;
            $display("ERROR: MODE %0d beat %0d is %h, expected %h", m, recv[m],
                     m_payload[m], beat(recv[m]));
          end
          recv[m] <= recv[m] + 1;
          if (recv[m] + 1 == N_RANDOM + N_RATE) done_cycle[m] <= cycle + 1;
        end
      end
    end
  end

  function automatic int unsigned expected_rate_cycles(input int unsigned m);
    // From the edge phase rises: one edge for the sources to see it, then
    // N_RATE beats at the mode's rate, plus its latency.
    case (m)
      0, 2:    return N_RATE + 1;
      4:       return 2 * N_RATE + 1;
      default: return N_RATE + 2;
    endcase
  endfunction

  initial begin
    automatic logic all_done;
    error_count = 0;
    check_count = 0;
    phase = 1'b0;
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;

    // Phase 0: random flow until every mode has delivered every beat.
    do begin
      @(posedge clk);
      all_done = 1'b1;
      for (int m = 0; m < MODES; m++) all_done &= (recv[m] == N_RANDOM);
    end while (!all_done);

    // Phase 1: full rate, starting on this edge.
    #1 phase = 1'b1;
    phase_start = cycle;
    do begin
      @(posedge clk);
      all_done = 1'b1;
      for (int m = 0; m < MODES; m++) all_done &= (recv[m] == N_RANDOM + N_RATE);
    end while (!all_done);
    @(posedge clk); #1;

    for (int m = 0; m < MODES; m++) begin
      check_count++;
      if (done_cycle[m] - phase_start != expected_rate_cycles(m)) begin
        error_count++;
        $display("ERROR: MODE %0d took %0d cycles for %0d full-rate beats, expected %0d",
                 m, done_cycle[m] - phase_start, N_RATE, expected_rate_cycles(m));
      end
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_axi4_stream_slice (%0d checks, all %0d modes)",
               check_count, MODES);
      $finish;
    end else begin
      $display("TEST FAILED: tb_axi4_stream_slice, %0d error(s) in %0d checks",
               error_count, check_count);
      $fatal(1, "tb_axi4_stream_slice failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 200000);
    $fatal(1, "tb_axi4_stream_slice: global timeout");
  end

endmodule

`default_nettype wire
