//=============================================================================
// Testbench   : tb_fifo_async
// Description : Self-checking SystemVerilog testbench for fifo_async.
//
// Streams words across two unrelated clocks with a non-integer period ratio,
// with back-pressure on the read side, and checks that every word arrives
// exactly once and in order. The run is long enough for the pointers to wrap
// many times, which is the only way the guard bit that distinguishes full from
// empty is actually exercised.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_fifo_async;

  localparam int unsigned DATA_WIDTH  = 32;
  localparam int unsigned DEPTH       = 16;
  localparam int unsigned SYNC_STAGES = 2;
  localparam int unsigned LEVEL_WIDTH = $clog2(DEPTH + 1);
  localparam int unsigned NUM_WORDS   = 600;

  localparam time WR_PERIOD = 10ns;
  localparam time RD_PERIOD = 23ns;

  logic                   wr_clk, wr_rst_n;
  logic                   s_valid, s_ready;
  logic [DATA_WIDTH-1:0]  s_data;
  logic [LEVEL_WIDTH-1:0] wr_level;
  logic                   wr_full, wr_almost_full;

  logic                   rd_clk, rd_rst_n;
  logic                   m_valid, m_ready;
  logic [DATA_WIDTH-1:0]  m_data;
  logic [LEVEL_WIDTH-1:0] rd_level;
  logic                   rd_empty, rd_almost_empty;

  int unsigned            error_count;
  int unsigned            sent_count;
  int unsigned            recv_count;
  logic                   writer_done;

  logic [DATA_WIDTH-1:0]  expected [$];

  fifo_async #(
      .DATA_WIDTH  (DATA_WIDTH),
      .DEPTH       (DEPTH),
      .SYNC_STAGES (SYNC_STAGES)
  ) dut (
      .wr_clk          (wr_clk),
      .wr_rst_n        (wr_rst_n),
      .s_valid         (s_valid),
      .s_ready         (s_ready),
      .s_data          (s_data),
      .wr_level        (wr_level),
      .wr_full         (wr_full),
      .wr_almost_full  (wr_almost_full),
      .rd_clk          (rd_clk),
      .rd_rst_n        (rd_rst_n),
      .m_valid         (m_valid),
      .m_ready         (m_ready),
      .m_data          (m_data),
      .rd_level        (rd_level),
      .rd_empty        (rd_empty),
      .rd_almost_empty (rd_almost_empty)
  );

  initial begin
    wr_clk = 1'b0;
    forever #(WR_PERIOD / 2) wr_clk = ~wr_clk;
  end

  initial begin
    rd_clk = 1'b0;
    #4ns;
    forever #(RD_PERIOD / 2) rd_clk = ~rd_clk;
  end

  //---------------------------------------------------------------------------
  // Read-side monitor
  //---------------------------------------------------------------------------
  always_ff @(posedge rd_clk) begin
    if (rd_rst_n && m_valid && m_ready) begin
      if (expected.size() == 0) begin
        error_count++;
        $error("received 0x%0h which was never written, at %0t", m_data, $time);
      end else begin
        automatic logic [DATA_WIDTH-1:0] want = expected.pop_front();
        recv_count++;
        if (m_data !== want) begin
          error_count++;
          $error("word %0d: expected 0x%0h, got 0x%0h at %0t",
                 recv_count, want, m_data, $time);
        end
      end
    end
  end

  //---------------------------------------------------------------------------
  // wr_level must never exceed DEPTH
  //---------------------------------------------------------------------------
  always_ff @(posedge wr_clk) begin
    if (wr_rst_n && (wr_level > LEVEL_WIDTH'(DEPTH))) begin
      error_count++;
      $error("wr_level %0d exceeds DEPTH %0d at %0t", wr_level, DEPTH, $time);
    end
  end

  //---------------------------------------------------------------------------
  // Writer
  //---------------------------------------------------------------------------
  initial begin : writer
    writer_done = 1'b0;
    s_valid     = 1'b0;
    s_data      = '0;
    sent_count  = 0;

    wait (wr_rst_n);
    @(posedge wr_clk);

    for (int unsigned i = 0; i < NUM_WORDS; i++) begin
      @(negedge wr_clk);
      s_valid = 1'b1;
      s_data  = DATA_WIDTH'(32'h1000_0000 + i);
      do begin
        @(posedge wr_clk);
      end while (s_ready !== 1'b1);
      expected.push_back(DATA_WIDTH'(32'h1000_0000 + i));
      sent_count++;
      @(negedge wr_clk);
      s_valid = 1'b0;
      repeat ($urandom_range(0, 2)) @(posedge wr_clk);
    end

    writer_done = 1'b1;
  end

  //---------------------------------------------------------------------------
  // Reader, with randomised back-pressure
  //---------------------------------------------------------------------------
  initial begin : reader
    m_ready = 1'b0;
    wait (rd_rst_n);
    forever begin
      @(negedge rd_clk);
      m_ready = ($urandom_range(0, 3) != 0);
    end
  end

  //---------------------------------------------------------------------------
  // Control
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    recv_count  = 0;
    wr_rst_n    = 1'b0;
    rd_rst_n    = 1'b0;

    repeat (4) @(posedge wr_clk);
    repeat (4) @(posedge rd_clk);
    #1;
    wr_rst_n = 1'b1;
    rd_rst_n = 1'b1;
    @(posedge wr_clk);
    #1;

    if (wr_full !== 1'b0 || rd_empty !== 1'b1 || s_ready !== 1'b1) begin
      error_count++;
      $error("reset state wrong: wr_full=%0b rd_empty=%0b s_ready=%0b",
             wr_full, rd_empty, s_ready);
    end

    wait (writer_done);
    wait (expected.size() == 0);
    repeat (32) @(posedge rd_clk);

    if (recv_count != sent_count) begin
      error_count++;
      $error("count mismatch: sent %0d, received %0d", sent_count, recv_count);
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_fifo_async (%0d words, DEPTH=%0d, wr %0t / rd %0t)",
               recv_count, DEPTH, WR_PERIOD, RD_PERIOD);
      $finish;
    end else begin
      $display("TEST FAILED: tb_fifo_async, %0d error(s)", error_count);
      $fatal(1, "tb_fifo_async failed");
    end
  end

  initial begin
    #(WR_PERIOD * 500000);
    $fatal(1, "tb_fifo_async: global timeout");
  end

endmodule

`default_nettype wire
