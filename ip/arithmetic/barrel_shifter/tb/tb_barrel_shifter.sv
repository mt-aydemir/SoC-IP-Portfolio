//=============================================================================
// Testbench   : tb_barrel_shifter
// Description : Self-checking SystemVerilog testbench for barrel_shifter.
//
// The Python-free smoke test. It runs on any SystemVerilog simulator, which
// makes it the fastest signal during development and the fallback when cocotb
// is not available. The exhaustive directed, randomised and regression suites
// live in cocotb/test_barrel_shifter.py.
//
// The reference model builds each result bit by bit from the definition of the
// operation rather than with the shift operators the design uses, so the two
// cannot agree through a shared misunderstanding of SystemVerilog's shift
// semantics.
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

module tb_barrel_shifter;

  localparam int unsigned WIDTH      = 8;
  localparam int unsigned AMT_WIDTH  = $clog2(WIDTH);
  localparam int unsigned NUM_RANDOM = 3000;
  localparam time         SETTLE     = 1ns;

  localparam logic [WIDTH-1:0] MASK = {WIDTH{1'b1}};

  localparam logic [2:0] OP_SHIFT_LEFT   = 3'd0;
  localparam logic [2:0] OP_SHIFT_RIGHT  = 3'd1;
  localparam logic [2:0] OP_ARITH_RIGHT  = 3'd2;
  localparam logic [2:0] OP_ROTATE_LEFT  = 3'd3;
  localparam logic [2:0] OP_ROTATE_RIGHT = 3'd4;

  logic [WIDTH-1:0]     data_in;
  logic [AMT_WIDTH-1:0] amount;
  logic [2:0]           operation;
  logic [WIDTH-1:0]     data_out;

  int unsigned          error_count;
  int unsigned          check_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  barrel_shifter #(
      .WIDTH (WIDTH)
  ) dut (
      .data_in   (data_in),
      .amount    (amount),
      .operation (operation),
      .data_out  (data_out)
  );

  //---------------------------------------------------------------------------
  // Reference model, built one bit at a time from the definition of each
  // operation. WIDTH is a power of two here, so every representable amount is
  // in range and no modulo reduction is needed.
  //---------------------------------------------------------------------------
  function automatic logic [WIDTH-1:0] model(input logic [WIDTH-1:0]     mdata,
                                             input logic [AMT_WIDTH-1:0] mamount,
                                             input logic [2:0]           mop);
    logic [WIDTH-1:0] result;
    int               amt;
    int               source_index;

    amt    = int'(mamount);
    result = '0;

    unique case (mop)
      OP_SHIFT_LEFT: begin
        for (int i = 0; i < int'(WIDTH); i++) begin
          source_index = i - amt;
          result[i] = (source_index >= 0) ? mdata[source_index] : 1'b0;
        end
      end
      OP_SHIFT_RIGHT: begin
        for (int i = 0; i < int'(WIDTH); i++) begin
          source_index = i + amt;
          result[i] = (source_index < int'(WIDTH)) ? mdata[source_index] : 1'b0;
        end
      end
      OP_ARITH_RIGHT: begin
        for (int i = 0; i < int'(WIDTH); i++) begin
          source_index = i + amt;
          result[i] = (source_index < int'(WIDTH)) ? mdata[source_index]
                                                   : mdata[WIDTH-1];
        end
      end
      OP_ROTATE_LEFT: begin
        for (int i = 0; i < int'(WIDTH); i++) begin
          source_index = ((i - amt) % int'(WIDTH) + int'(WIDTH)) % int'(WIDTH);
          result[i] = mdata[source_index];
        end
      end
      OP_ROTATE_RIGHT: begin
        for (int i = 0; i < int'(WIDTH); i++) begin
          source_index = (i + amt) % int'(WIDTH);
          result[i] = mdata[source_index];
        end
      end
      default: result = mdata;   // the unused encodings pass through
    endcase

    return result;
  endfunction

  //---------------------------------------------------------------------------
  // Apply one vector and check the result.
  //---------------------------------------------------------------------------
  task automatic apply(input logic [WIDTH-1:0]     vdata,
                       input logic [AMT_WIDTH-1:0] vamount,
                       input logic [2:0]           vop);
    logic [WIDTH-1:0] want;

    data_in   = vdata;
    amount    = vamount;
    operation = vop;
    #SETTLE;

    want = model(vdata, vamount, vop);
    check_count++;

    if (data_out !== want) begin
      error_count++;
      $error("op=%0d data=0x%0h amount=%0d: expected 0x%0h, got 0x%0h",
             vop, vdata, vamount, want, data_out);
    end
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    check_count = 0;

    // --- directed: a shift of zero passes the data through ------------------
    for (int unsigned op = 0; op < 8; op++) begin
      apply(MASK, '0, 3'(op));
      apply('0, '0, 3'(op));
      apply(WIDTH'('hA5), '0, 3'(op));
    end

    // --- directed: sign extension on the arithmetic right shift -------------
    for (int unsigned amt = 0; amt < WIDTH; amt++) begin
      apply({1'b1, {(WIDTH-1){1'b0}}}, AMT_WIDTH'(amt), OP_ARITH_RIGHT);
      apply(MASK, AMT_WIDTH'(amt), OP_ARITH_RIGHT);
      apply(MASK >> 1, AMT_WIDTH'(amt), OP_ARITH_RIGHT);
    end

    // --- exhaustive: every operation, every amount, every data pattern ------
    for (int unsigned op = 0; op < 8; op++) begin
      for (int unsigned amt = 0; amt < (1 << AMT_WIDTH); amt++) begin
        for (int unsigned value = 0; value <= int'(MASK); value++) begin
          apply(WIDTH'(value), AMT_WIDTH'(amt), 3'(op));
        end
      end
    end

    // --- regression: the rotate round trip restores the input ---------------
    for (int unsigned i = 0; i < 200; i++) begin
      logic [WIDTH-1:0]     value;
      logic [AMT_WIDTH-1:0] amt;
      logic [WIDTH-1:0]     rotated;

      value = WIDTH'($urandom());
      amt   = AMT_WIDTH'($urandom());

      apply(value, amt, OP_ROTATE_LEFT);
      rotated = data_out;
      apply(rotated, amt, OP_ROTATE_RIGHT);

      if (data_out !== value) begin
        error_count++;
        $error("rotate round trip by %0d did not restore 0x%0h (got 0x%0h)",
               amt, value, data_out);
      end
    end

    // --- randomised ---------------------------------------------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      apply(WIDTH'($urandom()), AMT_WIDTH'($urandom()), 3'($urandom()));
    end

    // --- verdict ------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_barrel_shifter (%0d vectors, WIDTH=%0d)",
               check_count, WIDTH);
      $finish;
    end else begin
      $display("TEST FAILED: tb_barrel_shifter, %0d error(s) in %0d vectors",
               error_count, check_count);
      $fatal(1, "tb_barrel_shifter failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(SETTLE * 1000000);
    $fatal(1, "tb_barrel_shifter: global timeout");
  end

endmodule

`default_nettype wire
