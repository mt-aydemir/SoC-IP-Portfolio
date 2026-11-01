//=============================================================================
// Testbench   : tb_systolic_pe
// Description : Self-checking SystemVerilog testbench for systolic_pe.
//
// Checks the three things a processing element must get right: the product is
// signed and wide enough for the extremes, the accumulate lands exactly one
// cycle after its operands, and a weight sitting in the shift chain has no
// arithmetic effect until it is committed.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_systolic_pe;

  localparam int unsigned DATA_WIDTH = 8;
  localparam int unsigned ACC_WIDTH  = 32;
  localparam time         CLK_PERIOD = 4ns;
  localparam int unsigned NUM_RANDOM = 2000;

  localparam int signed DATA_MIN = -(2 ** (DATA_WIDTH - 1));
  localparam int signed DATA_MAX = (2 ** (DATA_WIDTH - 1)) - 1;

  logic                        clk;
  logic                        rst_n;
  logic                        w_shift;
  logic                        w_commit;
  logic signed [DATA_WIDTH-1:0] w_in;
  logic signed [DATA_WIDTH-1:0] w_out;
  logic signed [DATA_WIDTH-1:0] a_in;
  logic signed [DATA_WIDTH-1:0] a_out;
  logic signed [ACC_WIDTH-1:0]  psum_in;
  logic signed [ACC_WIDTH-1:0]  psum_out;

  int unsigned error_count;
  int unsigned check_count;

  systolic_pe #(
      .DATA_WIDTH (DATA_WIDTH),
      .ACC_WIDTH  (ACC_WIDTH)
  ) dut (
      .clk      (clk),
      .rst_n    (rst_n),
      .w_shift  (w_shift),
      .w_commit (w_commit),
      .w_in     (w_in),
      .w_out    (w_out),
      .a_in     (a_in),
      .a_out    (a_out),
      .psum_in  (psum_in),
      .psum_out (psum_out)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Load one weight into the shift chain, optionally publishing it.
  //---------------------------------------------------------------------------
  task automatic load_weight(input logic signed [DATA_WIDTH-1:0] value,
                             input bit commit);
    @(negedge clk);
    w_in    = value;
    w_shift = 1'b1;
    @(negedge clk);
    w_shift = 1'b0;
    if (commit) begin
      w_commit = 1'b1;
      @(negedge clk);
      w_commit = 1'b0;
    end
  endtask

  //---------------------------------------------------------------------------
  // Apply one operand pair and check the result that appears one cycle later.
  //---------------------------------------------------------------------------
  task automatic check_mac(input logic signed [DATA_WIDTH-1:0] weight,
                           input logic signed [DATA_WIDTH-1:0] activation,
                           input logic signed [ACC_WIDTH-1:0]  psum);
    logic signed [ACC_WIDTH-1:0] expected;
    @(negedge clk);
    a_in    = activation;
    psum_in = psum;
    expected = psum + ACC_WIDTH'(weight * activation);
    @(posedge clk);
    #1;
    check_count++;
    if (psum_out !== expected) begin
      error_count++;
      $error("mac: %0d + %0d*%0d expected %0d, got %0d",
             psum, weight, activation, expected, psum_out);
    end
    if (a_out !== activation) begin
      error_count++;
      $error("activation %0d did not reach a_out (got %0d)",
             activation, a_out);
    end
  endtask

  initial begin
    logic signed [DATA_WIDTH-1:0] weight;
    logic signed [DATA_WIDTH-1:0] activation;
    logic signed [ACC_WIDTH-1:0]  psum;

    error_count = 0;
    check_count = 0;
    rst_n       = 1'b0;
    w_shift     = 1'b0;
    w_commit    = 1'b0;
    w_in        = '0;
    a_in        = '0;
    psum_in     = '0;

    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    #1;

    // --- reset state ---------------------------------------------------------
    if (psum_out !== '0 || a_out !== '0 || w_out !== '0) begin
      error_count++;
      $error("reset state wrong: psum_out=%0d a_out=%0d w_out=%0d",
             psum_out, a_out, w_out);
    end

    // --- the signed extremes -------------------------------------------------
    load_weight(DATA_MIN, 1'b1);
    check_mac(DATA_MIN, DATA_MIN, 0);
    check_mac(DATA_MIN, DATA_MAX, 0);
    check_mac(DATA_MIN, -1, 0);

    load_weight(DATA_MAX, 1'b1);
    check_mac(DATA_MAX, DATA_MAX, 0);
    check_mac(DATA_MAX, DATA_MIN, ACC_WIDTH'(1) <<< (ACC_WIDTH - 2));

    // --- the double buffer ---------------------------------------------------
    load_weight(2, 1'b1);
    check_mac(2, 10, 0);
    load_weight(-5, 1'b0);          // staged, not published
    check_mac(2, 10, 0);            // must still use the committed weight
    @(negedge clk);
    w_commit = 1'b1;
    @(negedge clk);
    w_commit = 1'b0;
    check_mac(-5, 10, 0);

    // --- the shift chain hands the staged weight upwards ---------------------
    load_weight(DATA_MIN, 1'b0);
    #1;
    if (w_out !== DATA_MIN) begin
      error_count++;
      $error("w_out should present the staged weight %0d, got %0d",
             DATA_MIN, w_out);
    end

    // --- randomised operands -------------------------------------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      weight     = DATA_WIDTH'($urandom_range(0, 2 ** DATA_WIDTH - 1));
      activation = DATA_WIDTH'($urandom_range(0, 2 ** DATA_WIDTH - 1));
      // Two bits clear of the extremes so a correct accumulate cannot
      // legitimately overflow; the RTL assertion is watching for one that does.
      psum       = ACC_WIDTH'($urandom()) >>> 2;
      load_weight(weight, 1'b1);
      check_mac(weight, activation, psum);
    end

    // --- verdict -------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_systolic_pe (%0d checks)", check_count);
      $finish;
    end else begin
      $display("TEST FAILED: tb_systolic_pe, %0d error(s)", error_count);
      $fatal(1, "tb_systolic_pe failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 500000);
    $fatal(1, "tb_systolic_pe: global timeout");
  end

endmodule

`default_nettype wire
