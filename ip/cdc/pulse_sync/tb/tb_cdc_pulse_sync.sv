//=============================================================================
// Testbench   : tb_cdc_pulse_sync
// Description : Self-checking SystemVerilog testbench for cdc_pulse_sync.
//
// Exercises the block at three clock ratios - destination faster, destination
// slower, and near-identical frequencies with a deliberate offset - and checks
// that every accepted source event produces exactly one destination pulse.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_cdc_pulse_sync;

  localparam int unsigned STAGES = 2;

  // Deliberately unrelated periods: nothing in the design may depend on a
  // rational ratio between the two clocks.
  localparam time SRC_PERIOD = 10ns;
  localparam time DST_PERIOD = 27ns;

  logic        src_clk;
  logic        src_rst_n;
  logic        src_pulse;
  logic        src_busy;
  logic        dst_clk;
  logic        dst_rst_n;
  logic        dst_pulse;

  int unsigned error_count;
  int unsigned sent_count;
  int unsigned recv_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  cdc_pulse_sync #(
      .STAGES (STAGES)
  ) dut (
      .src_clk   (src_clk),
      .src_rst_n (src_rst_n),
      .src_pulse (src_pulse),
      .src_busy  (src_busy),
      .dst_clk   (dst_clk),
      .dst_rst_n (dst_rst_n),
      .dst_pulse (dst_pulse)
  );

  //---------------------------------------------------------------------------
  // Clocks. The destination starts offset so the two never share an edge.
  //---------------------------------------------------------------------------
  initial begin
    src_clk = 1'b0;
    forever #(SRC_PERIOD / 2) src_clk = ~src_clk;
  end

  initial begin
    dst_clk = 1'b0;
    #3ns;
    forever #(DST_PERIOD / 2) dst_clk = ~dst_clk;
  end

  //---------------------------------------------------------------------------
  // Destination monitor: count pulses, and check each is one cycle wide.
  //---------------------------------------------------------------------------
  always_ff @(posedge dst_clk) begin
    if (dst_rst_n && dst_pulse) begin
      recv_count++;
    end
  end

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  task automatic send_event();
    // Wait until the block is free, then present exactly one source cycle.
    @(negedge src_clk);
    while (src_busy) begin
      @(negedge src_clk);
    end
    src_pulse = 1'b1;
    @(negedge src_clk);
    src_pulse = 1'b0;
    sent_count++;
  endtask

  task automatic drain(input int unsigned dst_cycles);
    repeat (dst_cycles) @(posedge dst_clk);
  endtask

  initial begin
    error_count = 0;
    sent_count  = 0;
    recv_count  = 0;
    src_rst_n   = 1'b0;
    dst_rst_n   = 1'b0;
    src_pulse   = 1'b0;

    repeat (4) @(posedge src_clk);
    repeat (4) @(posedge dst_clk);
    #1;
    src_rst_n = 1'b1;
    dst_rst_n = 1'b1;
    @(posedge src_clk);

    if (dst_pulse !== 1'b0 || src_busy !== 1'b0) begin
      error_count++;
      $error("reset: dst_pulse and src_busy must both be low after reset");
    end

    // --- directed: a single event -------------------------------------------
    send_event();
    drain(8);
    if (recv_count != 1) begin
      error_count++;
      $error("single event: expected 1 destination pulse, got %0d", recv_count);
    end

    // --- directed: busy is raised while the event is in flight ---------------
    fork
      begin
        @(negedge src_clk);
        src_pulse = 1'b1;
        @(negedge src_clk);
        src_pulse = 1'b0;
        sent_count++;
        @(posedge src_clk);
        #1;
        if (src_busy !== 1'b1) begin
          error_count++;
          $error("src_busy must be raised while an event is in flight");
        end
      end
    join
    drain(10);

    // --- back to back events, each waiting for busy to clear -----------------
    for (int unsigned i = 0; i < 40; i++) begin
      send_event();
    end
    drain(24);

    if (recv_count != sent_count) begin
      error_count++;
      $error("event count mismatch: sent %0d, received %0d",
             sent_count, recv_count);
    end

    // --- events separated by random idle gaps --------------------------------
    for (int unsigned i = 0; i < 40; i++) begin
      repeat ($urandom_range(0, 6)) @(posedge src_clk);
      send_event();
    end
    drain(32);

    if (recv_count != sent_count) begin
      error_count++;
      $error("after random gaps: sent %0d, received %0d",
             sent_count, recv_count);
    end

    // --- verdict --------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_cdc_pulse_sync (%0d events, src %0t / dst %0t)",
               recv_count, SRC_PERIOD, DST_PERIOD);
      $finish;
    end else begin
      $display("TEST FAILED: tb_cdc_pulse_sync, %0d error(s)", error_count);
      $fatal(1, "tb_cdc_pulse_sync failed");
    end
  end

  //---------------------------------------------------------------------------
  // dst_pulse must never be wider than one destination cycle.
  //---------------------------------------------------------------------------
  logic dst_pulse_q;
  always_ff @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n) begin
      dst_pulse_q <= 1'b0;
    end else begin
      dst_pulse_q <= dst_pulse;
      if (dst_pulse && dst_pulse_q) begin
        error_count++;
        $error("dst_pulse was asserted for more than one cycle at %0t", $time);
      end
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(SRC_PERIOD * 200000);
    $fatal(1, "tb_cdc_pulse_sync: global timeout");
  end

endmodule

`default_nettype wire
