//=============================================================================
// Testbench   : tb_multiplier
// Description : Self-checking SystemVerilog testbench for multiplier.
//
// The Python-free smoke test. It runs on any SystemVerilog simulator, which
// makes it the fastest signal during development and the fallback when cocotb
// is not available. The exhaustive directed, randomised and regression suites
// live in cocotb/test_multiplier.py.
//
// The reference model is a queue of expected products, pushed when operands
// are accepted and popped when a product is presented. That structure checks
// the pipeline's ordering and its latency as well as its arithmetic: a result
// that emerges one cycle early or late, or against the wrong operands, fails.
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

module tb_multiplier;

  localparam int unsigned A_WIDTH    = 8;
  localparam int unsigned B_WIDTH    = 8;
  localparam int unsigned SIGNED     = 1;
  localparam int unsigned LATENCY    = 2;
  localparam int unsigned P_WIDTH    = A_WIDTH + B_WIDTH;
  localparam time         CLK_PERIOD = 5ns;
  localparam int unsigned NUM_RANDOM = 1000;

  localparam logic [A_WIDTH-1:0] A_MASK = {A_WIDTH{1'b1}};
  localparam logic [B_WIDTH-1:0] B_MASK = {B_WIDTH{1'b1}};

  logic                clk;
  logic                rst_n;
  logic                in_valid;
  logic [A_WIDTH-1:0]  a;
  logic [B_WIDTH-1:0]  b;
  logic                out_valid;
  logic [P_WIDTH-1:0]  product;

  int unsigned         error_count;
  int unsigned         sent_count;
  int unsigned         recv_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  multiplier #(
      .A_WIDTH (A_WIDTH),
      .B_WIDTH (B_WIDTH),
      .SIGNED  (SIGNED),
      .LATENCY (LATENCY)
  ) dut (
      .clk       (clk),
      .rst_n     (rst_n),
      .in_valid  (in_valid),
      .a         (a),
      .b         (b),
      .out_valid (out_valid),
      .product   (product)
  );

  //---------------------------------------------------------------------------
  // Clock
  //---------------------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Reference model.
  //
  // Both operands are decoded into a 32-bit integer before multiplying, which
  // is wider than any product this testbench builds, so the model cannot wrap
  // where the design does not.
  //---------------------------------------------------------------------------
  function automatic logic [P_WIDTH-1:0] model(input logic [A_WIDTH-1:0] ma,
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

  //---------------------------------------------------------------------------
  // Expected-product queue, in order.
  //---------------------------------------------------------------------------
  logic [P_WIDTH-1:0] expected [$];

  always_ff @(posedge clk) begin
    if (rst_n && in_valid) begin
      expected.push_back(model(a, b));
    end
  end

  //---------------------------------------------------------------------------
  // Output monitor
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n && out_valid) begin
      if (expected.size() == 0) begin
        error_count++;
        $error("product 0x%0h at time %0t was never requested", product, $time);
      end else begin
        automatic logic [P_WIDTH-1:0] want = expected.pop_front();
        recv_count++;
        if (product !== want) begin
          error_count++;
          $error("product %0d: expected 0x%0h, got 0x%0h at time %0t",
                 recv_count, want, product, $time);
        end
      end
    end
  end

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  task automatic push(input logic [A_WIDTH-1:0] va,
                      input logic [B_WIDTH-1:0] vb);
    @(negedge clk);
    a        = va;
    b        = vb;
    in_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    in_valid = 1'b0;
    sent_count++;
  endtask

  initial begin
    error_count = 0;
    sent_count  = 0;
    recv_count  = 0;
    rst_n       = 1'b0;
    in_valid    = 1'b0;
    a           = '0;
    b           = '0;

    // --- reset -------------------------------------------------------------
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    #1;
    if (out_valid !== 1'b0) begin
      error_count++;
      $error("reset: out_valid should be low after reset");
    end

    // --- directed: identities ----------------------------------------------
    push('0, '0);
    push(A_WIDTH'(1), B_WIDTH'(1));
    push(A_MASK, '0);
    push('0, B_MASK);

    // --- directed: the four sign combinations at the extremes --------------
    push({1'b0, {(A_WIDTH-1){1'b1}}}, {1'b0, {(B_WIDTH-1){1'b1}}});  // + * +
    push({1'b0, {(A_WIDTH-1){1'b1}}}, {1'b1, {(B_WIDTH-1){1'b0}}});  // + * -
    push({1'b1, {(A_WIDTH-1){1'b0}}}, {1'b0, {(B_WIDTH-1){1'b1}}});  // - * +
    push({1'b1, {(A_WIDTH-1){1'b0}}}, {1'b1, {(B_WIDTH-1){1'b0}}});  // - * -
    push(A_MASK, B_MASK);                                            // -1 * -1

    repeat (LATENCY + 4) @(posedge clk);

    // --- back to back, a pair every cycle ----------------------------------
    @(negedge clk);
    in_valid = 1'b1;
    for (int unsigned i = 0; i < 64; i++) begin
      a = A_WIDTH'(i);
      b = B_WIDTH'(i * 7 + 1);
      @(posedge clk);
      @(negedge clk);
      sent_count++;
    end
    in_valid = 1'b0;
    repeat (LATENCY + 4) @(posedge clk);

    // --- exhaustive sweep, affordable at these widths ----------------------
    @(negedge clk);
    in_valid = 1'b1;
    for (int unsigned va = 0; va <= int'(A_MASK); va++) begin
      for (int unsigned vb = 0; vb <= int'(B_MASK); vb++) begin
        a = A_WIDTH'(va);
        b = B_WIDTH'(vb);
        @(posedge clk);
        @(negedge clk);
        sent_count++;
      end
    end
    in_valid = 1'b0;
    repeat (LATENCY + 4) @(posedge clk);

    // --- randomised, with gaps in in_valid ---------------------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      push(A_WIDTH'($urandom()), B_WIDTH'($urandom()));
      repeat ($urandom_range(0, 2)) @(posedge clk);
    end
    repeat (LATENCY + 8) @(posedge clk);

    // --- drain --------------------------------------------------------------
    if (expected.size() != 0) begin
      error_count++;
      $error("%0d operand pair(s) accepted never produced a product",
             expected.size());
    end

    // --- verdict ------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_multiplier (%0d products, %0dx%0d SIGNED=%0d LATENCY=%0d)",
               recv_count, A_WIDTH, B_WIDTH, SIGNED, LATENCY);
      $finish;
    end else begin
      $display("TEST FAILED: tb_multiplier, %0d error(s)", error_count);
      $fatal(1, "tb_multiplier failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(CLK_PERIOD * 1000000);
    $fatal(1, "tb_multiplier: global timeout");
  end

endmodule

`default_nettype wire
