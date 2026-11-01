//=============================================================================
// Testbench   : tb_clk_gate
// Description : Self-checking SystemVerilog testbench for clk_gate.
//
// The whole value of this block is that it never produces a runt pulse, so the
// testbench measures every high and low phase of the gated clock with
// $realtime and fails on any that is not a full source phase. It deliberately
// changes the enable in the middle of the clock's high phase, which is exactly
// where a naive AND gate chops the pulse and where a correct implementation
// must not.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_clk_gate;

  localparam time         CLK_PERIOD = 10ns;
  localparam real         HALF_NS    = real'(CLK_PERIOD) / 2.0;
  localparam int unsigned NUM_RANDOM = 400;

  logic        clk;
  logic        enable;
  logic        test_en;
  logic        gated_clk;

  int unsigned error_count;
  int unsigned gated_edges;
  int unsigned checked_pulses;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  clk_gate dut (
      .clk       (clk),
      .enable    (enable),
      .test_en   (test_en),
      .gated_clk (gated_clk)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Pulse width monitor. Every high phase of gated_clk must be exactly one
  // source high phase wide - never narrower, which would be a runt.
  //---------------------------------------------------------------------------
  real gated_rise;
  real width;

  always @(posedge gated_clk) begin
    gated_rise = $realtime;
    gated_edges++;
  end

  always @(negedge gated_clk) begin
    width = $realtime - gated_rise;
    checked_pulses++;
    if (width < HALF_NS - 0.002 || width > HALF_NS + 0.002) begin
      error_count++;
      $error("runt pulse: gated_clk high for %.3f ns, expected %.3f ns at %0t",
             width, HALF_NS, $time);
    end
  end

  //---------------------------------------------------------------------------
  // The gated clock may only rise when the source clock is rising.
  //---------------------------------------------------------------------------
  always @(posedge gated_clk) begin
    if (clk !== 1'b1) begin
      error_count++;
      $error("gated_clk rose while the source clock was low, at %0t", $time);
    end
  end

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count    = 0;
    gated_edges    = 0;
    checked_pulses = 0;
    enable         = 1'b0;
    test_en        = 1'b0;
    gated_rise     = 0.0;

    // --- disabled: no edges at all ------------------------------------------
    repeat (20) @(posedge clk);
    #1;
    if (gated_edges != 0) begin
      error_count++;
      $error("disabled: %0d gated clock edge(s) were produced", gated_edges);
    end
    if (gated_clk !== 1'b0) begin
      error_count++;
      $error("disabled: gated_clk must stay low");
    end

    // --- enabled: one gated edge per source edge -----------------------------
    @(negedge clk);
    enable = 1'b1;
    gated_edges = 0;
    repeat (20) @(posedge clk);
    #1;
    if (gated_edges != 20) begin
      error_count++;
      $error("enabled: expected 20 gated edges, got %0d", gated_edges);
    end

    // --- the hard case: change enable in the middle of the high phase --------
    // A naive AND gate chops the current pulse here. The latch must absorb the
    // change and let the pulse complete.
    repeat (30) begin
      @(posedge clk);
      #(CLK_PERIOD / 4) enable = ~enable;
    end
    enable = 1'b1;
    repeat (4) @(posedge clk);

    // --- test_en forces the gate open ----------------------------------------
    @(negedge clk);
    enable  = 1'b0;
    test_en = 1'b1;
    gated_edges = 0;
    repeat (10) @(posedge clk);
    #1;
    if (gated_edges != 10) begin
      error_count++;
      $error("test_en: expected 10 gated edges with the gate forced open, got %0d",
             gated_edges);
    end
    test_en = 1'b0;

    // --- randomised enable toggling at random phases -------------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      @(posedge clk);
      #($urandom_range(1, 8) * (CLK_PERIOD / 10));
      enable = $urandom_range(0, 1);
    end

    enable = 1'b0;
    repeat (4) @(posedge clk);

    // --- verdict --------------------------------------------------------------
    if (checked_pulses < 100) begin
      error_count++;
      $error("only %0d pulses were measured; the test did not exercise the gate",
             checked_pulses);
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_clk_gate (%0d pulses measured, none runt)",
               checked_pulses);
      $finish;
    end else begin
      $display("TEST FAILED: tb_clk_gate, %0d error(s)", error_count);
      $fatal(1, "tb_clk_gate failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 100000);
    $fatal(1, "tb_clk_gate: global timeout");
  end

endmodule

`default_nettype wire
