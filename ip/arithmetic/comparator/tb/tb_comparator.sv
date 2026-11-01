//=============================================================================
// Testbench   : tb_comparator
// Description : Self-checking SystemVerilog testbench for comparator.
//
// The Python-free smoke test. It runs on any SystemVerilog simulator, which
// makes it the fastest signal during development and the fallback when cocotb
// is not available. The exhaustive directed, randomised and regression suites
// live in cocotb/test_comparator.py.
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

module tb_comparator;

  localparam int unsigned WIDTH      = 8;
  localparam int unsigned SIGNED     = 1;
  localparam int unsigned NUM_RANDOM = 2000;
  localparam time         SETTLE     = 1ns;

  localparam logic [WIDTH-1:0] MASK          = {WIDTH{1'b1}};
  localparam logic [WIDTH-1:0] MOST_POSITIVE = {1'b0, {(WIDTH-1){1'b1}}};
  localparam logic [WIDTH-1:0] MOST_NEGATIVE = {1'b1, {(WIDTH-1){1'b0}}};

  logic [WIDTH-1:0] a;
  logic [WIDTH-1:0] b;
  logic             equal;
  logic             not_equal;
  logic             less;
  logic             less_equal;
  logic             greater;
  logic             greater_equal;

  int unsigned      error_count;
  int unsigned      check_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  comparator #(
      .WIDTH  (WIDTH),
      .SIGNED (SIGNED)
  ) dut (
      .a             (a),
      .b             (b),
      .equal         (equal),
      .not_equal     (not_equal),
      .less          (less),
      .less_equal    (less_equal),
      .greater       (greater),
      .greater_equal (greater_equal)
  );

  //---------------------------------------------------------------------------
  // Reference model.
  //
  // The operands are decoded into 32-bit integers once, and the comparison is
  // then an ordinary signed one. That is a different route to the answer than
  // the design's, which keeps the bit patterns and selects between two typed
  // comparisons.
  //---------------------------------------------------------------------------
  function automatic int decode(input logic [WIDTH-1:0] value);
    if (SIGNED != 0) begin
      return int'(signed'(value));
    end else begin
      return int'({1'b0, value});
    end
  endfunction

  //---------------------------------------------------------------------------
  // Apply one vector and check all six outputs.
  //---------------------------------------------------------------------------
  task automatic apply(input logic [WIDTH-1:0] va,
                       input logic [WIDTH-1:0] vb);
    int x;
    int y;

    a = va;
    b = vb;
    #SETTLE;

    x = decode(va);
    y = decode(vb);
    check_count++;

    if (equal !== (x == y)) begin
      error_count++;
      $error("a=0x%0h b=0x%0h: equal expected %0b, got %0b",
             va, vb, (x == y), equal);
    end
    if (not_equal !== (x != y)) begin
      error_count++;
      $error("a=0x%0h b=0x%0h: not_equal expected %0b, got %0b",
             va, vb, (x != y), not_equal);
    end
    if (less !== (x < y)) begin
      error_count++;
      $error("a=0x%0h b=0x%0h: less expected %0b, got %0b",
             va, vb, (x < y), less);
    end
    if (less_equal !== (x <= y)) begin
      error_count++;
      $error("a=0x%0h b=0x%0h: less_equal expected %0b, got %0b",
             va, vb, (x <= y), less_equal);
    end
    if (greater !== (x > y)) begin
      error_count++;
      $error("a=0x%0h b=0x%0h: greater expected %0b, got %0b",
             va, vb, (x > y), greater);
    end
    if (greater_equal !== (x >= y)) begin
      error_count++;
      $error("a=0x%0h b=0x%0h: greater_equal expected %0b, got %0b",
             va, vb, (x >= y), greater_equal);
    end

    // Trichotomy: exactly one of less, equal, greater may hold. This is the
    // property that catches a signedness mistake without knowing the answer.
    if ($countones({less, equal, greater}) != 1) begin
      error_count++;
      $error("a=0x%0h b=0x%0h: less=%0b equal=%0b greater=%0b is not a total order",
             va, vb, less, equal, greater);
    end
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    check_count = 0;

    // --- directed: equality -------------------------------------------------
    apply('0, '0);
    apply(MASK, MASK);
    apply(MOST_NEGATIVE, MOST_NEGATIVE);

    // --- directed: the interpretation boundary ------------------------------
    apply(MASK, '0);                        // -1 vs 0, or max vs min
    apply(MASK, WIDTH'(1));
    apply(MOST_NEGATIVE, '0);
    apply(MOST_NEGATIVE, MOST_POSITIVE);
    apply(MOST_POSITIVE, MOST_NEGATIVE);

    // --- directed: adjacent values ------------------------------------------
    for (int unsigned value = 0; value < int'(MASK); value++) begin
      apply(WIDTH'(value), WIDTH'(value + 1));
      apply(WIDTH'(value + 1), WIDTH'(value));
    end

    // --- exhaustive sweep, affordable at this width -------------------------
    for (int unsigned va = 0; va <= int'(MASK); va++) begin
      for (int unsigned vb = 0; vb <= int'(MASK); vb++) begin
        apply(WIDTH'(va), WIDTH'(vb));
      end
    end

    // --- randomised ---------------------------------------------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      apply(WIDTH'($urandom()), WIDTH'($urandom()));
    end

    // --- verdict ------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_comparator (%0d vectors, WIDTH=%0d SIGNED=%0d)",
               check_count, WIDTH, SIGNED);
      $finish;
    end else begin
      $display("TEST FAILED: tb_comparator, %0d error(s) in %0d vectors",
               error_count, check_count);
      $fatal(1, "tb_comparator failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(SETTLE * 1000000);
    $fatal(1, "tb_comparator: global timeout");
  end

endmodule

`default_nettype wire
