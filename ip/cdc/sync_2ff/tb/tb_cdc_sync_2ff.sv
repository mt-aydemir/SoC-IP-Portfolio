//=============================================================================
// Testbench   : tb_cdc_sync_2ff
// Description : Self-checking SystemVerilog testbench for cdc_sync_2ff.
//
// This is the simulator-independent smoke test. It needs no Python and runs
// on any SystemVerilog simulator, which makes it the fastest way to sanity
// check the IP during development and the fallback when cocotb is not
// available. The exhaustive directed, randomised and regression suites live
// in cocotb/test_cdc_sync_2ff.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_cdc_sync_2ff;

  localparam int unsigned WIDTH      = 8;
  localparam int unsigned STAGES     = 3;
  localparam time         CLK_PERIOD = 4ns;

  logic             clk;
  logic             rst_n;
  logic [WIDTH-1:0] d_async;
  logic [WIDTH-1:0] q_sync;

  int unsigned      error_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  cdc_sync_2ff #(
      .WIDTH       (WIDTH),
      .STAGES      (STAGES),
      .RESET_VALUE ('0)
  ) dut (
      .clk     (clk),
      .rst_n   (rst_n),
      .d_async (d_async),
      .q_sync  (q_sync)
  );

  //---------------------------------------------------------------------------
  // Clock
  //---------------------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Reference model: a STAGES-deep shift register clocked alongside the DUT
  //---------------------------------------------------------------------------
  logic [WIDTH-1:0] model [STAGES];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int unsigned s = 0; s < STAGES; s++) begin
        model[s] <= '0;
      end
    end else begin
      model[0] <= d_async;
      for (int unsigned s = 1; s < STAGES; s++) begin
        model[s] <= model[s-1];
      end
    end
  end

  //---------------------------------------------------------------------------
  // Continuous comparison, sampled safely after each clock edge
  //---------------------------------------------------------------------------
  task automatic check(input string context_name);
    if (q_sync !== model[STAGES-1]) begin
      error_count++;
      $error("%s: expected 0x%0h, got 0x%0h at time %0t",
             context_name, model[STAGES-1], q_sync, $time);
    end
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    rst_n       = 1'b0;
    d_async     = '0;

    // --- reset -------------------------------------------------------------
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    if (q_sync !== '0) begin
      error_count++;
      $error("reset: q_sync should be 0 after reset, got 0x%0h", q_sync);
    end

    // --- directed: exact propagation latency --------------------------------
    @(negedge clk);
    d_async = '1;
    for (int unsigned i = 1; i <= STAGES; i++) begin
      @(posedge clk);
      #1;
      if (q_sync !== ((i >= STAGES) ? {WIDTH{1'b1}} : {WIDTH{1'b0}})) begin
        error_count++;
        $error("latency: wrong output at stage %0d (0x%0h)", i, q_sync);
      end
    end

    // --- randomised traffic --------------------------------------------------
    for (int unsigned i = 0; i < 500; i++) begin
      @(negedge clk);
      d_async = WIDTH'($urandom());
      @(posedge clk);
      #1 check($sformatf("random[%0d]", i));
    end

    // --- worst case toggling -------------------------------------------------
    for (int unsigned i = 0; i < 100; i++) begin
      @(negedge clk);
      d_async = ~d_async;
      @(posedge clk);
      #1 check($sformatf("toggle[%0d]", i));
    end

    // --- asynchronous reset in the middle of traffic -------------------------
    @(posedge clk);
    #(CLK_PERIOD / 4) rst_n = 1'b0;
    #1;
    if (q_sync !== '0) begin
      error_count++;
      $error("async reset: output did not clear immediately (0x%0h)", q_sync);
    end
    repeat (2) @(posedge clk);
    #1 rst_n = 1'b1;

    for (int unsigned i = 0; i < 2 * STAGES; i++) begin
      @(negedge clk);
      d_async = WIDTH'($urandom());
      @(posedge clk);
      #1 check($sformatf("refill[%0d]", i));
    end

    // --- verdict --------------------------------------------------------------
    repeat (2) @(posedge clk);
    if (error_count == 0) begin
      $display("TEST PASSED: tb_cdc_sync_2ff (WIDTH=%0d, STAGES=%0d)", WIDTH, STAGES);
      $finish;
    end else begin
      $display("TEST FAILED: tb_cdc_sync_2ff, %0d error(s)", error_count);
      $fatal(1, "tb_cdc_sync_2ff failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(CLK_PERIOD * 5000);
    $fatal(1, "tb_cdc_sync_2ff: global timeout");
  end

endmodule

`default_nettype wire
