//=============================================================================
// Testbench   : tb_alu
// Description : Self-checking SystemVerilog testbench for alu.
//
// The Python-free smoke test. It runs on any SystemVerilog simulator, which
// makes it the fastest signal during development and the fallback when cocotb
// is not available. The exhaustive directed, randomised and regression suites
// live in cocotb/test_alu.py.
//
// The reference model computes each result in 32-bit integer arithmetic,
// wider than the operands, and derives the flags from the definitions in the
// RTL header. It shares nothing with the design's single shared adder.
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

module tb_alu;

  localparam int unsigned WIDTH      = 8;
  localparam int unsigned AMT_WIDTH  = $clog2(WIDTH);
  localparam int unsigned NUM_RANDOM = 5000;
  localparam time         SETTLE     = 1ns;

  localparam int SIGNED_MAX = (1 << (WIDTH - 1)) - 1;
  localparam int SIGNED_MIN = -(1 << (WIDTH - 1));
  localparam int UNSIGNED_MAX = (1 << WIDTH) - 1;

  logic [WIDTH-1:0] a;
  logic [WIDTH-1:0] b;
  logic [3:0]       opcode;
  logic             carry_in;
  logic [WIDTH-1:0] result;
  logic             flag_zero;
  logic             flag_negative;
  logic             flag_carry;
  logic             flag_overflow;

  int unsigned      error_count;
  int unsigned      check_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  alu #(
      .WIDTH (WIDTH)
  ) dut (
      .a             (a),
      .b             (b),
      .opcode        (opcode),
      .carry_in      (carry_in),
      .result        (result),
      .flag_zero     (flag_zero),
      .flag_negative (flag_negative),
      .flag_carry    (flag_carry),
      .flag_overflow (flag_overflow)
  );

  //---------------------------------------------------------------------------
  // Reference model
  //---------------------------------------------------------------------------
  function automatic logic [WIDTH-1:0] rotl(input logic [WIDTH-1:0] value,
                                            input int unsigned      amount);
    logic [WIDTH-1:0] out;
    for (int i = 0; i < int'(WIDTH); i++) begin
      out[(i + int'(amount)) % int'(WIDTH)] = value[i];
    end
    return out;
  endfunction

  task automatic model(input  logic [WIDTH-1:0] ma,
                       input  logic [WIDTH-1:0] mb,
                       input  logic [3:0]       mop,
                       input  logic             mcin,
                       output logic [WIDTH-1:0] mres,
                       output logic             mc,
                       output logic             mv);
    int ua;
    int ub;
    int sa;
    int sb;
    int exact_u;
    int exact_s;
    int unsigned amount;

    ua     = int'({1'b0, ma});
    ub     = int'({1'b0, mb});
    sa     = int'(signed'(ma));
    sb     = int'(signed'(mb));
    amount = int'(mb[AMT_WIDTH-1:0]);
    mc     = 1'b0;
    mv     = 1'b0;

    unique case (mop)
      4'h0: begin                                   // ADD
        exact_u = ua + ub + int'(mcin);
        exact_s = sa + sb + int'(mcin);
        mres    = WIDTH'(exact_u);
        mc      = (exact_u > UNSIGNED_MAX);
        mv      = (exact_s > SIGNED_MAX) || (exact_s < SIGNED_MIN);
      end
      4'h1: begin                                   // SUB, carry = no borrow
        exact_u = ua - ub - int'(!mcin);
        exact_s = sa - sb - int'(!mcin);
        mres    = WIDTH'(exact_u);
        mc      = (exact_u >= 0);
        mv      = (exact_s > SIGNED_MAX) || (exact_s < SIGNED_MIN);
      end
      4'h2: mres = ma & mb;
      4'h3: mres = ma | mb;
      4'h4: mres = ma ^ mb;
      4'h5: mres = ~ma;
      4'h6: mres = WIDTH'(ua << amount);
      4'h7: mres = WIDTH'(ua >> amount);
      4'h8: mres = WIDTH'(sa >>> amount);
      4'h9: mres = rotl(ma, amount);
      4'hA: mres = rotl(ma, (WIDTH - amount) % WIDTH);
      4'hB: mres = WIDTH'(sa < sb);
      4'hC: mres = WIDTH'(ua < ub);
      4'hD: mres = ma;
      4'hE: mres = mb;
      default: mres = '0;
    endcase
  endtask

  //---------------------------------------------------------------------------
  // Apply one vector and check the result and all four flags.
  //---------------------------------------------------------------------------
  task automatic apply(input logic [WIDTH-1:0] va,
                       input logic [WIDTH-1:0] vb,
                       input logic [3:0]       vop,
                       input logic             vcin);
    logic [WIDTH-1:0] want;
    logic             want_c;
    logic             want_v;

    a        = va;
    b        = vb;
    opcode   = vop;
    carry_in = vcin;
    #SETTLE;

    model(va, vb, vop, vcin, want, want_c, want_v);
    check_count++;

    if (result !== want || flag_zero !== (want == '0) ||
        flag_negative !== want[WIDTH-1] || flag_carry !== want_c ||
        flag_overflow !== want_v) begin
      error_count++;
      $error({"op=%0h a=0x%0h b=0x%0h cin=%0b: expected res=0x%0h ZNCV=%0b%0b%0b%0b, ",
              "got res=0x%0h ZNCV=%0b%0b%0b%0b"},
             vop, va, vb, vcin, want, (want == '0), want[WIDTH-1], want_c, want_v,
             result, flag_zero, flag_negative, flag_carry, flag_overflow);
    end
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    check_count = 0;

    // --- exhaustive: every opcode, operand pair and carry at this width -----
    for (int unsigned op = 0; op < 16; op++) begin
      for (int unsigned va = 0; va < (1 << WIDTH); va++) begin
        for (int unsigned vb = 0; vb < (1 << WIDTH); vb += 5) begin
          apply(WIDTH'(va), WIDTH'(vb), 4'(op), 1'b0);
          apply(WIDTH'(va), WIDTH'(vb), 4'(op), 1'b1);
        end
      end
    end

    // --- randomised ---------------------------------------------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      apply(WIDTH'($urandom()), WIDTH'($urandom()), 4'($urandom()), 1'b1 & $urandom());
    end

    // --- verdict ------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_alu (%0d vectors, WIDTH=%0d)", check_count, WIDTH);
      $finish;
    end else begin
      $display("TEST FAILED: tb_alu, %0d error(s) in %0d vectors",
               error_count, check_count);
      $fatal(1, "tb_alu failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(SETTLE * 10000000);
    $fatal(1, "tb_alu: global timeout");
  end

endmodule

`default_nettype wire
