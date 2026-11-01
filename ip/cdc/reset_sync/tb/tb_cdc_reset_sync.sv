//=============================================================================
// Testbench   : tb_cdc_reset_sync
// Description : Self-checking SystemVerilog testbench for cdc_reset_sync.
//
// Checks the two properties that define a reset synchroniser:
//   * assertion is immediate and needs no clock;
//   * release happens exactly STAGES clock edges after the input rises.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_cdc_reset_sync;

  localparam int unsigned STAGES     = 3;
  localparam time         CLK_PERIOD = 10ns;

  logic        clk;
  logic        arst_n_in;
  logic        rst_n_out;

  int unsigned error_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  cdc_reset_sync #(
      .STAGES (STAGES)
  ) dut (
      .clk       (clk),
      .arst_n_in (arst_n_in),
      .rst_n_out (rst_n_out)
  );

  //---------------------------------------------------------------------------
  // Clock
  //---------------------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  task automatic check(input logic actual, input logic expected,
                       input string context_name);
    if (actual !== expected) begin
      error_count++;
      $error("%s: expected %0b, got %0b at time %0t",
             context_name, expected, actual, $time);
    end
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    arst_n_in   = 1'b0;

    // --- release takes exactly STAGES edges ---------------------------------
    repeat (4) @(posedge clk);
    check(rst_n_out, 1'b0, "output must stay asserted while the input is low");

    @(negedge clk);
    arst_n_in = 1'b1;
    for (int unsigned i = 1; i <= STAGES; i++) begin
      @(posedge clk);
      #1;
      check(rst_n_out, (i >= STAGES) ? 1'b1 : 1'b0,
            $sformatf("release edge %0d of %0d", i, STAGES));
    end

    // --- stays released -----------------------------------------------------
    repeat (5) @(posedge clk);
    #1 check(rst_n_out, 1'b1, "output must stay released");

    // --- assertion is immediate, away from any clock edge --------------------
    @(posedge clk);
    #(CLK_PERIOD / 3) arst_n_in = 1'b0;
    #1 check(rst_n_out, 1'b0, "assertion must not wait for a clock edge");

    // --- assertion works with the clock stopped -----------------------------
    @(negedge clk);
    arst_n_in = 1'b1;
    repeat (STAGES + 2) @(posedge clk);
    #1 check(rst_n_out, 1'b1, "output should be released again");

    // Stop observing the clock and assert reset between edges.
    @(posedge clk);
    #(CLK_PERIOD / 4) arst_n_in = 1'b0;
    #1 check(rst_n_out, 1'b0, "assertion with no intervening edge");

    // --- a glitch shorter than a clock period is still captured -------------
    @(negedge clk);
    arst_n_in = 1'b1;
    repeat (STAGES + 2) @(posedge clk);
    #1 check(rst_n_out, 1'b1, "released before the glitch");

    @(posedge clk);
    #1 arst_n_in = 1'b0;
    #(CLK_PERIOD / 8) arst_n_in = 1'b1;
    // The asynchronous clear has already taken effect, so the output must be
    // low and must take the full STAGES edges to come back.
    #1 check(rst_n_out, 1'b0, "a sub-cycle glitch must still assert the reset");

    for (int unsigned i = 1; i <= STAGES; i++) begin
      @(posedge clk);
      #1;
      check(rst_n_out, (i >= STAGES) ? 1'b1 : 1'b0,
            $sformatf("recovery after glitch, edge %0d", i));
    end

    // --- verdict ------------------------------------------------------------
    repeat (2) @(posedge clk);
    if (error_count == 0) begin
      $display("TEST PASSED: tb_cdc_reset_sync (STAGES=%0d)", STAGES);
      $finish;
    end else begin
      $display("TEST FAILED: tb_cdc_reset_sync, %0d error(s)", error_count);
      $fatal(1, "tb_cdc_reset_sync failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(CLK_PERIOD * 5000);
    $fatal(1, "tb_cdc_reset_sync: global timeout");
  end

endmodule

`default_nettype wire
