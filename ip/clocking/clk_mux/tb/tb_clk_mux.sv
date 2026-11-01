//=============================================================================
// Testbench   : tb_clk_mux
// Description : Self-checking SystemVerilog testbench for clk_mux.
//
// The failure this block exists to prevent is a runt pulse at the moment of
// switching, so the testbench measures every high and low phase of the output
// and fails on any that is shorter than the narrower of the two source phases.
// The output is allowed to be *long* - that is the dead time between one clock
// releasing and the other taking over - but never short.
//
// The select input is deliberately changed at random times, asynchronous to
// both clocks, because that is how an integrator will drive it.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_clk_mux;

  localparam int unsigned STAGES = 2;

  // Unrelated periods. clk1 is deliberately not a multiple of clk0.
  localparam time CLK0_PERIOD = 10ns;
  localparam time CLK1_PERIOD = 27ns;

  // The narrowest legal phase on the output is the narrower source half period.
  localparam real MIN_PHASE_NS =
      (real'(CLK0_PERIOD) < real'(CLK1_PERIOD) ?
       real'(CLK0_PERIOD) : real'(CLK1_PERIOD)) / 2.0;

  localparam int unsigned NUM_SWITCHES = 60;

  logic        clk0;
  logic        clk1;
  logic        rst0_n;
  logic        rst1_n;
  logic        select;
  logic        clk_active;
  logic        clk_out;

  int unsigned error_count;
  int unsigned out_edges;
  int unsigned phases_checked;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  clk_mux #(
      .STAGES (STAGES)
  ) dut (
      .clk0    (clk0),
      .clk1    (clk1),
      .rst0_n  (rst0_n),
      .rst1_n  (rst1_n),
      .select     (select),
      .clk_active (clk_active),
      .clk_out    (clk_out)
  );

  //---------------------------------------------------------------------------
  // Switch request honouring the block's usage rule: hold select stable until
  // clk_active has followed it.
  //---------------------------------------------------------------------------
  task automatic request_clock(input logic which);
    int unsigned guard;
    select = which;
    guard  = 0;
    // Bounded poll rather than an unbounded wait, so a design that never
    // completes the switch fails here with a clear message instead of hanging
    // until the global timeout.
    while (clk_active !== which && guard < 4000) begin
      #1ns;
      guard++;
    end
    if (clk_active !== which) begin
      error_count++;
      $error("switch to clk%0d never completed", which);
    end
  endtask

  initial begin
    clk0 = 1'b0;
    forever #(CLK0_PERIOD / 2) clk0 = ~clk0;
  end

  initial begin
    clk1 = 1'b0;
    #3ns;
    forever #(CLK1_PERIOD / 2) clk1 = ~clk1;
  end

  //---------------------------------------------------------------------------
  // Phase width monitor: no phase on the output may be shorter than the
  // narrowest source phase. A shorter one is a runt and would violate the
  // minimum pulse width of every downstream flip-flop.
  //---------------------------------------------------------------------------
  real last_edge;
  real phase;
  logic monitoring;

  always @(posedge clk_out or negedge clk_out) begin
    if (monitoring) begin
      phase = $realtime - last_edge;
      phases_checked++;
      if (phase < MIN_PHASE_NS - 0.002) begin
        error_count++;
        $error("runt phase on clk_out: %.3f ns at %0t (minimum legal %.3f ns)",
               phase, $time, MIN_PHASE_NS);
      end
    end
    last_edge  = $realtime;
    monitoring = 1'b1;
    out_edges++;
  end

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count    = 0;
    out_edges      = 0;
    phases_checked = 0;
    monitoring     = 1'b0;
    last_edge      = 0.0;
    select         = 1'b0;
    rst0_n         = 1'b0;
    rst1_n         = 1'b0;

    repeat (4) @(posedge clk0);
    repeat (4) @(posedge clk1);
    #1;
    rst0_n = 1'b1;
    rst1_n = 1'b1;

    // --- reset selects clk0 ---------------------------------------------------
    out_edges = 0;
    repeat (20) @(posedge clk0);
    #1;
    if (out_edges < 15) begin
      error_count++;
      $error("after reset the output should follow clk0; saw %0d edges", out_edges);
    end

    // --- switch to clk1 -------------------------------------------------------
    @(posedge clk0);
    #(CLK0_PERIOD / 3);
    request_clock(1'b1);

    out_edges = 0;
    repeat (20) @(posedge clk1);
    #1;
    if (out_edges < 15) begin
      error_count++;
      $error("after switching the output should follow clk1; saw %0d edges",
             out_edges);
    end

    // --- switch back ----------------------------------------------------------
    @(posedge clk1);
    #(CLK1_PERIOD / 4);
    request_clock(1'b0);

    out_edges = 0;
    repeat (20) @(posedge clk0);
    #1;
    if (out_edges < 15) begin
      error_count++;
      $error("after switching back the output should follow clk0; saw %0d edges",
             out_edges);
    end

    // --- randomised switching, respecting the usage rule ----------------------
    for (int unsigned i = 0; i < NUM_SWITCHES; i++) begin
      #($urandom_range(5, 120) * 1ns);
      request_clock(~clk_active);
    end

    request_clock(1'b0);
    repeat (20) @(posedge clk0);

    //--------------------------------------------------------------------------
    // Robustness: violate the usage rule on purpose.
    //
    // Withdrawing a request part way through a changeover is not supported
    // usage, but it must still never glitch: the chains clear rather than
    // shift, so a stale request cannot complete behind the withdrawal. The
    // phase monitor above is what actually checks this.
    //--------------------------------------------------------------------------
    for (int unsigned i = 0; i < NUM_SWITCHES; i++) begin
      #($urandom_range(3, 40) * 1ns);
      select = ~select;
    end

    request_clock(1'b0);
    repeat (20) @(posedge clk0);

    // --- verdict --------------------------------------------------------------
    if (phases_checked < 200) begin
      error_count++;
      $error("only %0d phases were measured; the test did not exercise the mux",
             phases_checked);
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_clk_mux (%0d phases measured, none runt)",
               phases_checked);
      $finish;
    end else begin
      $display("TEST FAILED: tb_clk_mux, %0d error(s)", error_count);
      $fatal(1, "tb_clk_mux failed");
    end
  end

  initial begin
    #(CLK0_PERIOD * 500000);
    $fatal(1, "tb_clk_mux: global timeout");
  end

endmodule

`default_nettype wire
