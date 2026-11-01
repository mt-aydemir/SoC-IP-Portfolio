//=============================================================================
// Testbench   : tb_mac
// Description : Self-checking SystemVerilog testbench for mac.
//
// The Python-free smoke test. It runs on any SystemVerilog simulator, which
// makes it the fastest signal during development and the fallback when cocotb
// is not available. The exhaustive directed, randomised and regression suites
// live in cocotb/test_mac.py.
//
// The reference is a cycle-accurate model of the structure - one multiplier
// stage, a clear delayed by the same amount, then the accumulate - kept in
// 64-bit integers so it cannot itself overflow. It is written that way
// because the property under test is the alignment between those stages, not
// the arithmetic.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed. The driver
// treats a missing banner as a failure, so a testbench that dies early cannot
// be mistaken for a pass.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_mac;

  localparam int unsigned A_WIDTH     = 8;
  localparam int unsigned B_WIDTH     = 8;
  localparam int unsigned ACC_WIDTH   = 24;
  localparam int unsigned SIGNED      = 1;
  localparam int unsigned SATURATE    = 0;
  localparam int unsigned P_WIDTH     = A_WIDTH + B_WIDTH;
  localparam int unsigned MUL_LATENCY = 1;
  localparam time         CLK_PERIOD  = 5ns;
  localparam int unsigned NUM_RANDOM  = 3000;

  localparam logic [A_WIDTH-1:0] A_MASK = {A_WIDTH{1'b1}};
  localparam logic [B_WIDTH-1:0] B_MASK = {B_WIDTH{1'b1}};

  logic                  clk;
  logic                  rst_n;
  logic                  in_valid;
  logic                  clear;
  logic [A_WIDTH-1:0]    a;
  logic [B_WIDTH-1:0]    b;
  logic                  out_valid;
  logic [ACC_WIDTH-1:0]  acc_out;
  logic                  overflow;

  // Reference pipeline: the multiplier stage and the clear travelling with it.
  logic                  ref_mul_valid;
  logic [P_WIDTH-1:0]    ref_mul_product;
  logic                  ref_clear_pipe;
  logic [ACC_WIDTH-1:0]  ref_acc;
  logic                  ref_out_valid;

  int unsigned           error_count;
  int unsigned           check_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  mac #(
      .A_WIDTH   (A_WIDTH),
      .B_WIDTH   (B_WIDTH),
      .ACC_WIDTH (ACC_WIDTH),
      .SIGNED    (SIGNED),
      .SATURATE  (SATURATE)
  ) dut (
      .clk       (clk),
      .rst_n     (rst_n),
      .in_valid  (in_valid),
      .clear     (clear),
      .a         (a),
      .b         (b),
      .out_valid (out_valid),
      .acc_out   (acc_out),
      .overflow  (overflow)
  );

  //---------------------------------------------------------------------------
  // Clock
  //---------------------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Reference helpers
  //---------------------------------------------------------------------------
  function automatic logic [P_WIDTH-1:0] product_of(input logic [A_WIDTH-1:0] ma,
                                                    input logic [B_WIDTH-1:0] mb);
    int x;
    int y;

    if (SIGNED != 0) begin
      x = int'(signed'(ma));
      y = int'(signed'(mb));
    end else begin
      x = int'({1'b0, ma});
      y = int'({1'b0, mb});
    end
    return P_WIDTH'(x * y);
  endfunction

  function automatic logic [ACC_WIDTH-1:0] widen(input logic [P_WIDTH-1:0] p);
    if (SIGNED != 0) begin
      return ACC_WIDTH'(signed'(p));
    end else begin
      return ACC_WIDTH'(p);
    end
  endfunction

  //---------------------------------------------------------------------------
  // Cycle-accurate reference model.
  //
  // Saturation is left out deliberately: this testbench runs the unsaturated
  // configuration, where the accumulator wraps, so the model needs only
  // modular addition. The saturating configuration is covered by the cocotb
  // suite, which follows the parameter.
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ref_mul_valid   <= 1'b0;
      ref_mul_product <= '0;
      ref_clear_pipe  <= 1'b0;
      ref_acc         <= '0;
      ref_out_valid   <= 1'b0;
    end else begin
      // The accumulate stage, driven by what the multiplier stage holds now.
      if (ref_clear_pipe && ref_mul_valid) begin
        ref_acc <= widen(ref_mul_product);
      end else if (ref_mul_valid) begin
        ref_acc <= ref_acc + widen(ref_mul_product);
      end

      ref_out_valid <= ref_mul_valid;

      // The multiplier stage, driven by this edge's inputs.
      ref_mul_valid   <= in_valid;
      ref_mul_product <= product_of(a, b);
      ref_clear_pipe  <= clear && in_valid;
    end
  end

  //---------------------------------------------------------------------------
  // Comparison
  //---------------------------------------------------------------------------
  task automatic check(input string label);
    #1;
    check_count++;

    if (acc_out !== ref_acc) begin
      error_count++;
      $error("%s: acc_out expected 0x%0h, got 0x%0h at time %0t",
             label, ref_acc, acc_out, $time);
    end
    if (out_valid !== ref_out_valid) begin
      error_count++;
      $error("%s: out_valid expected %0b, got %0b at time %0t",
             label, ref_out_valid, out_valid, $time);
    end
  endtask

  task automatic step(input logic vvalid,
                      input logic vclear,
                      input logic [A_WIDTH-1:0] va,
                      input logic [B_WIDTH-1:0] vb,
                      input string label = "step");
    @(negedge clk);
    in_valid = vvalid;
    clear    = vclear;
    a        = va;
    b        = vb;
    @(posedge clk);
    check(label);
  endtask

  task automatic idle_cycles(input int unsigned count);
    for (int unsigned i = 0; i < count; i++) begin
      step(1'b0, 1'b0, '0, '0, "idle");
    end
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    check_count = 0;
    rst_n       = 1'b0;
    in_valid    = 1'b0;
    clear       = 1'b0;
    a           = '0;
    b           = '0;

    // --- reset -------------------------------------------------------------
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    check("after reset");

    if (out_valid !== 1'b0) begin
      error_count++;
      $error("reset: out_valid should be low after reset");
    end

    // --- directed: a short dot product --------------------------------------
    step(1'b1, 1'b1, A_WIDTH'(2), B_WIDTH'(3), "frame sample 0");
    step(1'b1, 1'b0, A_WIDTH'(4), B_WIDTH'(5), "frame sample 1");
    step(1'b1, 1'b0, A_WIDTH'(6), B_WIDTH'(7), "frame sample 2");
    idle_cycles(MUL_LATENCY + 3);

    if (acc_out !== ACC_WIDTH'(2*3 + 4*5 + 6*7)) begin
      error_count++;
      $error("dot product: expected %0d, got %0d", 2*3 + 4*5 + 6*7, acc_out);
    end

    // --- directed: back to back frames, no gap at the boundary --------------
    // This is where an unaligned clear shows up: the second frame starts
    // while the first still has a product in the multiplier.
    step(1'b1, 1'b1, A_WIDTH'(3), B_WIDTH'(3), "second frame sample 0");
    step(1'b1, 1'b0, A_WIDTH'(5), B_WIDTH'(5), "second frame sample 1");
    idle_cycles(MUL_LATENCY + 3);

    if (acc_out !== ACC_WIDTH'(3*3 + 5*5)) begin
      error_count++;
      $error("second frame: expected %0d, got %0d (residue from frame 1?)",
             3*3 + 5*5, acc_out);
    end

    // --- directed: gaps inside a frame --------------------------------------
    step(1'b1, 1'b1, A_WIDTH'(2), B_WIDTH'(3), "gapped frame sample 0");
    idle_cycles(2);
    step(1'b1, 1'b0, A_WIDTH'(4), B_WIDTH'(5), "gapped frame sample 1");
    idle_cycles(3);
    step(1'b1, 1'b0, A_WIDTH'(6), B_WIDTH'(7), "gapped frame sample 2");
    idle_cycles(MUL_LATENCY + 3);

    if (acc_out !== ACC_WIDTH'(2*3 + 4*5 + 6*7)) begin
      error_count++;
      $error("gapped frame: expected %0d, got %0d", 2*3 + 4*5 + 6*7, acc_out);
    end

    // --- directed: the sign combinations ------------------------------------
    step(1'b1, 1'b1, {1'b1, {(A_WIDTH-1){1'b0}}}, {1'b1, {(B_WIDTH-1){1'b0}}},
         "most negative squared");
    step(1'b1, 1'b0, A_MASK, B_MASK, "minus one squared");
    step(1'b1, 1'b0, {1'b0, {(A_WIDTH-1){1'b1}}}, {1'b1, {(B_WIDTH-1){1'b0}}},
         "positive times negative");
    idle_cycles(MUL_LATENCY + 3);

    // --- randomised: independent valid and clear every cycle ----------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      step(($urandom_range(0, 3) != 0),      // in_valid, mostly asserted
           ($urandom_range(0, 7) == 0),      // clear, occasionally
           A_WIDTH'($urandom()),
           B_WIDTH'($urandom()),
           "random");
    end
    idle_cycles(MUL_LATENCY + 3);

    // --- verdict ------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_mac (%0d checks, %0dx%0d -> %0d bits SIGNED=%0d)",
               check_count, A_WIDTH, B_WIDTH, ACC_WIDTH, SIGNED);
      $finish;
    end else begin
      $display("TEST FAILED: tb_mac, %0d error(s) in %0d checks",
               error_count, check_count);
      $fatal(1, "tb_mac failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(CLK_PERIOD * 1000000);
    $fatal(1, "tb_mac: global timeout");
  end

endmodule

`default_nettype wire
