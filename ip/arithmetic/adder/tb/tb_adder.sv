//=============================================================================
// Testbench   : tb_adder
// Description : Self-checking SystemVerilog testbench for adder.
//
// The Python-free smoke test. It runs on any SystemVerilog simulator, which
// makes it the fastest signal during development and the fallback when cocotb
// is not available. The exhaustive directed, randomised and regression suites
// live in cocotb/test_adder.py.
//
// The block is combinational, so there is no clock: each vector is applied,
// allowed to settle, and checked. The reference model below is derived from
// the specification in the RTL header, not from its body.
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

module tb_adder;

  localparam int unsigned WIDTH      = 8;
  localparam int unsigned SIGNED     = 1;
  localparam int unsigned SATURATE   = 1;
  localparam int unsigned NUM_RANDOM = 2000;
  localparam time         SETTLE     = 1ns;

  localparam logic [WIDTH-1:0] MASK          = {WIDTH{1'b1}};
  localparam logic [WIDTH-1:0] MOST_POSITIVE = {1'b0, {(WIDTH-1){1'b1}}};
  localparam logic [WIDTH-1:0] MOST_NEGATIVE = {1'b1, {(WIDTH-1){1'b0}}};

  logic [WIDTH-1:0] a;
  logic [WIDTH-1:0] b;
  logic             carry_in;
  logic [WIDTH-1:0] sum;
  logic             carry_out;
  logic             overflow;

  int unsigned      error_count;
  int unsigned      check_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  adder #(
      .WIDTH    (WIDTH),
      .SIGNED   (SIGNED),
      .SATURATE (SATURATE)
  ) dut (
      .a         (a),
      .b         (b),
      .carry_in  (carry_in),
      .sum       (sum),
      .carry_out (carry_out),
      .overflow  (overflow)
  );

  //---------------------------------------------------------------------------
  // Reference model, written from the documented specification.
  //---------------------------------------------------------------------------
  task automatic model(input  logic [WIDTH-1:0] ma,
                       input  logic [WIDTH-1:0] mb,
                       input  logic             mcin,
                       output logic [WIDTH-1:0] msum,
                       output logic             mcarry,
                       output logic             movf);
    logic [WIDTH:0]   wide;
    logic [WIDTH-1:0] raw;

    wide   = {1'b0, ma} + {1'b0, mb} + (WIDTH+1)'(mcin);
    raw    = wide[WIDTH-1:0];
    mcarry = wide[WIDTH];

    if (SIGNED != 0) begin
      movf = (ma[WIDTH-1] == mb[WIDTH-1]) && (raw[WIDTH-1] != ma[WIDTH-1]);
    end else begin
      movf = mcarry;
    end

    if ((SATURATE == 0) || !movf) begin
      msum = raw;
    end else if (SIGNED != 0) begin
      msum = ma[WIDTH-1] ? MOST_NEGATIVE : MOST_POSITIVE;
    end else begin
      msum = MASK;
    end
  endtask

  //---------------------------------------------------------------------------
  // Apply one vector and check every output against the model.
  //---------------------------------------------------------------------------
  task automatic apply(input logic [WIDTH-1:0] va,
                       input logic [WIDTH-1:0] vb,
                       input logic             vcin);
    logic [WIDTH-1:0] want_sum;
    logic             want_carry;
    logic             want_overflow;

    a        = va;
    b        = vb;
    carry_in = vcin;
    #SETTLE;

    model(va, vb, vcin, want_sum, want_carry, want_overflow);
    check_count++;

    if (sum !== want_sum) begin
      error_count++;
      $error("a=0x%0h b=0x%0h cin=%0b: sum expected 0x%0h, got 0x%0h",
             va, vb, vcin, want_sum, sum);
    end
    if (carry_out !== want_carry) begin
      error_count++;
      $error("a=0x%0h b=0x%0h cin=%0b: carry_out expected %0b, got %0b",
             va, vb, vcin, want_carry, carry_out);
    end
    if (overflow !== want_overflow) begin
      error_count++;
      $error("a=0x%0h b=0x%0h cin=%0b: overflow expected %0b, got %0b",
             va, vb, vcin, want_overflow, overflow);
    end
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    check_count = 0;

    // --- directed: identities and the carry in as a plus one ---------------
    apply('0, '0, 1'b0);
    apply('0, '0, 1'b1);
    apply(WIDTH'(1), '0, 1'b0);
    apply('0, WIDTH'(1), 1'b0);
    apply(MASK, '0, 1'b1);

    // --- directed: the unsigned wrap point ---------------------------------
    apply(MASK, WIDTH'(1), 1'b0);
    apply(MASK, MASK, 1'b0);
    apply(MASK, MASK, 1'b1);

    // --- directed: the signed overflow corners -----------------------------
    apply(MOST_POSITIVE, WIDTH'(1), 1'b0);      // positive + positive
    apply(MOST_POSITIVE, MOST_POSITIVE, 1'b0);
    apply(MOST_NEGATIVE, MASK, 1'b0);           // negative + -1
    apply(MOST_NEGATIVE, MOST_NEGATIVE, 1'b0);
    apply(MOST_POSITIVE, MOST_NEGATIVE, 1'b0);  // opposite signs never overflow
    apply(MOST_POSITIVE, '0, 1'b1);             // the carry in alone overflows

    // --- directed: the carry chain -----------------------------------------
    for (int unsigned bit_index = 0; bit_index < WIDTH; bit_index++) begin
      apply(MASK, WIDTH'(1) << bit_index, 1'b0);
      apply((WIDTH'(1) << bit_index) - WIDTH'(1), WIDTH'(1), 1'b0);
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
      $display("TEST PASSED: tb_adder (%0d vectors, WIDTH=%0d SIGNED=%0d SATURATE=%0d)",
               check_count, WIDTH, SIGNED, SATURATE);
      $finish;
    end else begin
      $display("TEST FAILED: tb_adder, %0d error(s) in %0d vectors",
               error_count, check_count);
      $fatal(1, "tb_adder failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(SETTLE * 1000000);
    $fatal(1, "tb_adder: global timeout");
  end

endmodule

`default_nettype wire
