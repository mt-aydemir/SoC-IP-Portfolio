//=============================================================================
// Testbench   : tb_fifo_sync
// Description : Self-checking SystemVerilog testbench for fifo_sync.
//
// Checks the three things a FIFO must get right: every word comes back once
// and in order, the occupancy reported matches reality, and the capacity is
// exactly DEPTH - no more, and no less.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_fifo_sync;

  localparam int unsigned DATA_WIDTH  = 32;
  localparam int unsigned DEPTH       = 16;
  localparam int unsigned LEVEL_WIDTH = $clog2(DEPTH + 1);
  localparam time         CLK_PERIOD  = 10ns;
  localparam int unsigned NUM_RANDOM  = 800;

  logic                    clk;
  logic                    rst_n;
  logic                    s_valid;
  logic                    s_ready;
  logic [DATA_WIDTH-1:0]   s_data;
  logic                    m_valid;
  logic                    m_ready;
  logic [DATA_WIDTH-1:0]   m_data;
  logic [LEVEL_WIDTH-1:0]  level;
  logic                    full;
  logic                    empty;
  logic                    almost_full;
  logic                    almost_empty;

  int unsigned             error_count;
  int unsigned             sent_count;
  int unsigned             recv_count;

  logic [DATA_WIDTH-1:0]   expected [$];

  fifo_sync #(
      .DATA_WIDTH (DATA_WIDTH),
      .DEPTH      (DEPTH)
  ) dut (
      .clk          (clk),
      .rst_n        (rst_n),
      .s_valid      (s_valid),
      .s_ready      (s_ready),
      .s_data       (s_data),
      .m_valid      (m_valid),
      .m_ready      (m_ready),
      .m_data       (m_data),
      .level        (level),
      .full         (full),
      .empty        (empty),
      .almost_full  (almost_full),
      .almost_empty (almost_empty)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Output monitor
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n && m_valid && m_ready) begin
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
  // Level must never exceed the advertised capacity
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n && (level > LEVEL_WIDTH'(DEPTH))) begin
      error_count++;
      $error("level %0d exceeds DEPTH %0d at %0t", level, DEPTH, $time);
    end
  end

  task automatic push(input logic [DATA_WIDTH-1:0] value);
    @(negedge clk);
    s_valid = 1'b1;
    s_data  = value;
    do begin
      @(posedge clk);
    end while (s_ready !== 1'b1);
    expected.push_back(value);
    sent_count++;
    @(negedge clk);
    s_valid = 1'b0;
  endtask

  initial begin
    error_count = 0;
    sent_count  = 0;
    recv_count  = 0;
    rst_n       = 1'b0;
    s_valid     = 1'b0;
    s_data      = '0;
    m_ready     = 1'b0;

    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    #1;

    // --- reset state ---------------------------------------------------------
    if (level !== '0 || full !== 1'b0 || empty !== 1'b1 || m_valid !== 1'b0) begin
      error_count++;
      $error("reset state wrong: level=%0d full=%0b empty=%0b m_valid=%0b",
             level, full, empty, m_valid);
    end

    // --- first word falls through without being asked for --------------------
    push(32'hA5A5_A5A5);
    repeat (4) @(posedge clk);
    #1;
    if (m_valid !== 1'b1 || m_data !== 32'hA5A5_A5A5) begin
      error_count++;
      $error("first word fall through failed: m_valid=%0b m_data=0x%0h",
             m_valid, m_data);
    end

    // --- fill to exactly DEPTH -----------------------------------------------
    for (int unsigned i = 1; i < DEPTH; i++) begin
      push(DATA_WIDTH'(i));
    end
    repeat (6) @(posedge clk);
    #1;
    if (level !== LEVEL_WIDTH'(DEPTH) || full !== 1'b1 || s_ready !== 1'b0) begin
      error_count++;
      $error("not full at DEPTH words: level=%0d full=%0b s_ready=%0b",
             level, full, s_ready);
    end

    // --- drain in order -------------------------------------------------------
    @(negedge clk);
    m_ready = 1'b1;
    wait (expected.size() == 0);
    repeat (6) @(posedge clk);
    #1;
    if (level !== '0 || empty !== 1'b1) begin
      error_count++;
      $error("not empty after draining: level=%0d empty=%0b", level, empty);
    end

    // --- full rate streaming ---------------------------------------------------
    for (int unsigned i = 0; i < 200; i++) begin
      push(DATA_WIDTH'($urandom()));
    end
    repeat (16) @(posedge clk);

    // --- randomised traffic with sink back pressure ---------------------------
    sink_go = 1'b1;
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      push(DATA_WIDTH'($urandom()));
      repeat ($urandom_range(0, 2)) @(posedge clk);
    end
    sink_go = 1'b0;

    m_ready = 1'b1;
    repeat (64) @(posedge clk);

    // --- verdict ----------------------------------------------------------------
    if (expected.size() != 0) begin
      error_count++;
      $error("%0d word(s) were written but never read back", expected.size());
    end
    if (recv_count != sent_count) begin
      error_count++;
      $error("count mismatch: sent %0d, received %0d", sent_count, recv_count);
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_fifo_sync (%0d words, DEPTH=%0d)",
               recv_count, DEPTH);
      $finish;
    end else begin
      $display("TEST FAILED: tb_fifo_sync, %0d error(s)", error_count);
      $fatal(1, "tb_fifo_sync failed");
    end
  end

  //---------------------------------------------------------------------------
  // Sink back-pressure, driven from its own process. A fork inside the
  // stimulus block would call automatic tasks with timing controls from two
  // places at once, which Verilator 5.020 miscompiles.
  //---------------------------------------------------------------------------
  logic sink_go;

  initial begin : sink_backpressure
    sink_go = 1'b0;
    forever begin
      @(negedge clk);
      if (sink_go) begin
        m_ready = ($urandom_range(0, 3) != 0);
      end
    end
  end

  initial begin
    #(CLK_PERIOD * 500000);
    $fatal(1, "tb_fifo_sync: global timeout");
  end

endmodule

`default_nettype wire
