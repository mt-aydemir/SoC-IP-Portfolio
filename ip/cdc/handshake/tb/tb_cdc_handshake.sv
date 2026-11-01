//=============================================================================
// Testbench   : tb_cdc_handshake
// Description : Self-checking SystemVerilog testbench for cdc_handshake.
//
// Drives a stream of words across two unrelated clock domains and checks that
// every word arrives exactly once, in order, unaltered. Also exercises
// destination-side back-pressure, which must stall the source rather than
// dropping or duplicating a word.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_cdc_handshake;

  localparam int unsigned DATA_WIDTH = 16;
  localparam int unsigned STAGES     = 2;
  localparam int unsigned NUM_WORDS  = 200;

  // Unrelated periods with a non-integer ratio.
  localparam time SRC_PERIOD = 10ns;
  localparam time DST_PERIOD = 23ns;

  logic                  src_clk;
  logic                  src_rst_n;
  logic                  src_valid;
  logic                  src_ready;
  logic [DATA_WIDTH-1:0] src_data;

  logic                  dst_clk;
  logic                  dst_rst_n;
  logic                  dst_valid;
  logic                  dst_ready;
  logic [DATA_WIDTH-1:0] dst_data;

  int unsigned           error_count;
  int unsigned           sent_count;
  int unsigned           recv_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  cdc_handshake #(
      .DATA_WIDTH (DATA_WIDTH),
      .STAGES     (STAGES)
  ) dut (
      .src_clk   (src_clk),
      .src_rst_n (src_rst_n),
      .src_valid (src_valid),
      .src_ready (src_ready),
      .src_data  (src_data),
      .dst_clk   (dst_clk),
      .dst_rst_n (dst_rst_n),
      .dst_valid (dst_valid),
      .dst_ready (dst_ready),
      .dst_data  (dst_data)
  );

  //---------------------------------------------------------------------------
  // Clocks, offset so they never share an edge.
  //---------------------------------------------------------------------------
  initial begin
    src_clk = 1'b0;
    forever #(SRC_PERIOD / 2) src_clk = ~src_clk;
  end

  initial begin
    dst_clk = 1'b0;
    #4ns;
    forever #(DST_PERIOD / 2) dst_clk = ~dst_clk;
  end

  //---------------------------------------------------------------------------
  // Reference queue, written by the source driver and read by the monitor.
  //---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] expected [$];

  always_ff @(posedge dst_clk) begin
    if (dst_rst_n && dst_valid && dst_ready) begin
      if (expected.size() == 0) begin
        error_count++;
        $error("received 0x%0h which was never sent, at %0t", dst_data, $time);
      end else begin
        automatic logic [DATA_WIDTH-1:0] want = expected.pop_front();
        recv_count++;
        if (dst_data !== want) begin
          error_count++;
          $error("word %0d: expected 0x%0h, got 0x%0h at %0t",
                 recv_count, want, dst_data, $time);
        end
      end
    end
  end

  //---------------------------------------------------------------------------
  // Source driver
  //---------------------------------------------------------------------------
  task automatic send(input logic [DATA_WIDTH-1:0] value);
    @(negedge src_clk);
    src_valid = 1'b1;
    src_data  = value;
    expected.push_back(value);
    do begin
      @(posedge src_clk);
    end while (src_ready !== 1'b1);
    @(negedge src_clk);
    src_valid = 1'b0;
    sent_count++;
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    sent_count  = 0;
    recv_count  = 0;
    src_rst_n   = 1'b0;
    dst_rst_n   = 1'b0;
    src_valid   = 1'b0;
    src_data    = '0;
    dst_ready   = 1'b1;

    repeat (4) @(posedge src_clk);
    repeat (4) @(posedge dst_clk);
    #1;
    src_rst_n = 1'b1;
    dst_rst_n = 1'b1;
    @(posedge src_clk);
    #1;

    if (dst_valid !== 1'b0) begin
      error_count++;
      $error("reset: dst_valid must be low after reset");
    end
    if (src_ready !== 1'b1) begin
      error_count++;
      $error("reset: src_ready must be high after reset");
    end

    // --- directed: a single word --------------------------------------------
    send(DATA_WIDTH'('hBEEF));
    repeat (12) @(posedge dst_clk);
    if (recv_count != 1) begin
      error_count++;
      $error("single word: expected 1 transfer, got %0d", recv_count);
    end

    // --- streaming with an always-ready sink ---------------------------------
    for (int unsigned i = 0; i < NUM_WORDS; i++) begin
      send(DATA_WIDTH'($urandom()));
    end
    repeat (24) @(posedge dst_clk);

    // --- streaming against destination back-pressure -------------------------
    fork
      begin
        for (int unsigned i = 0; i < NUM_WORDS; i++) begin
          send(DATA_WIDTH'($urandom()));
        end
      end
      begin
        forever begin
          @(negedge dst_clk);
          dst_ready = ($urandom_range(0, 2) != 0);
        end
      end
    join_any
    disable fork;

    dst_ready = 1'b1;
    repeat (64) @(posedge dst_clk);

    // --- verdict --------------------------------------------------------------
    if (expected.size() != 0) begin
      error_count++;
      $error("%0d word(s) were sent but never arrived", expected.size());
    end
    if (recv_count != sent_count) begin
      error_count++;
      $error("count mismatch: sent %0d, received %0d", sent_count, recv_count);
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_cdc_handshake (%0d words, DATA_WIDTH=%0d)",
               recv_count, DATA_WIDTH);
      $finish;
    end else begin
      $display("TEST FAILED: tb_cdc_handshake, %0d error(s)", error_count);
      $fatal(1, "tb_cdc_handshake failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(SRC_PERIOD * 500000);
    $fatal(1, "tb_cdc_handshake: global timeout");
  end

endmodule

`default_nettype wire
