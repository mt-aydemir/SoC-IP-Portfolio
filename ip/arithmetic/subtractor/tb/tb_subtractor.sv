//=============================================================================
// Testbench   : tb_subtractor
// Description : Self-checking SystemVerilog testbench for subtractor.
//
// The Python-free smoke test. It runs on any SystemVerilog simulator, which
// makes it the fastest signal during development and the fallback when cocotb
// is not available. The exhaustive directed, randomised and regression suites
// live in cocotb/test_subtractor.py.
//
// The reference model computes the difference in a wider arithmetic than the
// design uses and then asks whether the value was representable, so it shares
// none of the design's inverted-operand reasoning.
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

module tb_subtractor;

  localparam int unsigned WIDTH      = 8;
  localparam int unsigned SIGNED     = 1;
  localparam int unsigned SATURATE   = 1;
  localparam int unsigned NUM_RANDOM = 2000;
  localparam time         SETTLE     = 1ns;

  localparam logic [WIDTH-1:0] MASK          = {WIDTH{1'b1}};
  localparam logic [WIDTH-1:0] MOST_POSITIVE = {1'b0, {(WIDTH-1){1'b1}}};
  localparam logic [WIDTH-1:0] MOST_NEGATIVE = {1'b1, {(WIDTH-1){1'b0}}};

  localparam int SIGNED_MAX = (1 << (WIDTH - 1)) - 1;
  localparam int SIGNED_MIN = -(1 << (WIDTH - 1));

  logic [WIDTH-1:0] a;
  logic [WIDTH-1:0] b;
  logic             borrow_in;
  logic [WIDTH-1:0] difference;
  logic             borrow_out;
  logic             overflow;

  int unsigned      error_count;
  int unsigned      check_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  subtractor #(
      .WIDTH    (WIDTH),
      .SIGNED   (SIGNED),
      .SATURATE (SATURATE)
  ) dut (
      .a          (a),
      .b          (b),
      .borrow_in  (borrow_in),
      .difference (difference),
      .borrow_out (borrow_out),
      .overflow   (overflow)
  );

  //---------------------------------------------------------------------------
  // Reference model, written from the specification.
  //
  // Both exact differences are computed in a 32-bit integer, which is wider
  // than any supported WIDTH, so neither can wrap in the model itself.
  //---------------------------------------------------------------------------
  task automatic model(input  logic [WIDTH-1:0] ma,
                       input  logic [WIDTH-1:0] mb,
                       input  logic             mbin,
                       output logic [WIDTH-1:0] mdiff,
                       output logic             mborrow,
                       output logic             movf);
    int               unsigned_true;
    int               signed_true;
    logic [WIDTH-1:0] raw;

    unsigned_true = int'({1'b0, ma}) - int'({1'b0, mb}) - int'(mbin);
    signed_true   = int'(signed'(ma)) - int'(signed'(mb)) - int'(mbin);

    raw     = WIDTH'(unsigned_true);
    mborrow = (unsigned_true < 0);

    if (SIGNED != 0) begin
      movf = (signed_true > SIGNED_MAX) || (signed_true < SIGNED_MIN);
    end else begin
      movf = mborrow;
    end

    if (SATURATE == 0) begin
      mdiff = raw;
    end else if (SIGNED != 0) begin
      if (movf) begin
        mdiff = (signed_true < 0) ? MOST_NEGATIVE : MOST_POSITIVE;
      end else begin
        mdiff = raw;
      end
    end else begin
      mdiff = mborrow ? '0 : raw;
    end
  endtask

  //---------------------------------------------------------------------------
  // Apply one vector and check every output against the model.
  //---------------------------------------------------------------------------
  task automatic apply(input logic [WIDTH-1:0] va,
                       input logic [WIDTH-1:0] vb,
                       input logic             vbin);
    logic [WIDTH-1:0] want_difference;
    logic             want_borrow;
    logic             want_overflow;

    a         = va;
    b         = vb;
    borrow_in = vbin;
    #SETTLE;

    model(va, vb, vbin, want_difference, want_borrow, want_overflow);
    check_count++;

    if (difference !== want_difference) begin
      error_count++;
      $error("a=0x%0h b=0x%0h bin=%0b: difference expected 0x%0h, got 0x%0h",
             va, vb, vbin, want_difference, difference);
    end
    if (borrow_out !== want_borrow) begin
      error_count++;
      $error("a=0x%0h b=0x%0h bin=%0b: borrow_out expected %0b, got %0b",
             va, vb, vbin, want_borrow, borrow_out);
    end
    if (overflow !== want_overflow) begin
      error_count++;
      $error("a=0x%0h b=0x%0h bin=%0b: overflow expected %0b, got %0b",
             va, vb, vbin, want_overflow, overflow);
    end
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    check_count = 0;

    // --- directed: identities ----------------------------------------------
    apply('0, '0, 1'b0);
    apply('0, '0, 1'b1);
    apply(MASK, '0, 1'b0);
    apply(MASK, MASK, 1'b0);
    apply(WIDTH'(42), WIDTH'(42), 1'b0);

    // --- directed: the borrow boundary --------------------------------------
    apply(WIDTH'(1), '0, 1'b0);
    apply('0, WIDTH'(1), 1'b0);
    apply(WIDTH'(1), WIDTH'(1), 1'b1);

    // --- directed: the signed overflow corners ------------------------------
    apply(MOST_POSITIVE, MASK, 1'b0);            // +max - (-1)
    apply(MOST_POSITIVE, MOST_NEGATIVE, 1'b0);   // +max - min
    apply(MOST_NEGATIVE, WIDTH'(1), 1'b0);       // min  - 1
    apply(MOST_NEGATIVE, MOST_POSITIVE, 1'b0);   // min  - max
    apply(MOST_NEGATIVE, '0, 1'b1);              // the borrow in alone
    apply(MOST_POSITIVE, MOST_POSITIVE, 1'b0);   // same sign, never overflows
    apply(MOST_NEGATIVE, MOST_NEGATIVE, 1'b0);

    // --- directed: the borrow chain -----------------------------------------
    for (int unsigned bit_index = 0; bit_index < WIDTH; bit_index++) begin
      apply('0, WIDTH'(1) << bit_index, 1'b0);
      apply(WIDTH'(1) << bit_index, WIDTH'(1), 1'b0);
    end

    // --- exhaustive sweep, affordable at this width -------------------------
    for (int unsigned va = 0; va <= int'(MASK); va++) begin
      for (int unsigned vb = 0; vb <= int'(MASK); vb++) begin
        apply(WIDTH'(va), WIDTH'(vb), 1'b0);
      end
    end

    // --- randomised ---------------------------------------------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      apply(WIDTH'($urandom()), WIDTH'($urandom()), 1'b1 & $urandom());
    end

    // --- verdict ------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_subtractor (%0d vectors, WIDTH=%0d SIGNED=%0d SATURATE=%0d)",
               check_count, WIDTH, SIGNED, SATURATE);
      $finish;
    end else begin
      $display("TEST FAILED: tb_subtractor, %0d error(s) in %0d vectors",
               error_count, check_count);
      $fatal(1, "tb_subtractor failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(SETTLE * 1000000);
    $fatal(1, "tb_subtractor: global timeout");
  end

endmodule

`default_nettype wire
