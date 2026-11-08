//=============================================================================
// Testbench   : tb_accumulator
// Description : Self-checking SystemVerilog testbench for accumulator.
//
// The Python-free smoke test. It runs on any SystemVerilog simulator, which
// makes it the fastest signal during development and the fallback when cocotb
// is not available. The exhaustive directed, randomised and regression suites
// live in cocotb/test_accumulator.py.
//
// The reference total is kept in a 64-bit signed integer, which is wider than
// any accumulator this testbench builds, and the limits are applied to that
// value. The model therefore decides what the answer should be in arithmetic
// that cannot itself overflow, rather than re-deriving the design's carry and
// sign conditions.
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

module tb_accumulator;

  localparam int unsigned DATA_WIDTH = 8;
  localparam int unsigned ACC_WIDTH  = 16;
  localparam int unsigned SIGNED     = 1;
  localparam int unsigned SATURATE   = 1;
  localparam time         CLK_PERIOD = 5ns;
  localparam int unsigned NUM_RANDOM = 4000;

  localparam logic [DATA_WIDTH-1:0] DATA_MASK = {DATA_WIDTH{1'b1}};
  localparam logic [ACC_WIDTH-1:0]  ACC_MASK  = {ACC_WIDTH{1'b1}};

  localparam longint MAX_SIGNED   = (64'd1 << (ACC_WIDTH - 1)) - 64'd1;
  localparam longint MIN_SIGNED   = -(64'd1 << (ACC_WIDTH - 1));
  localparam longint MAX_UNSIGNED = (64'd1 << ACC_WIDTH) - 64'd1;

  logic                   clk;
  logic                   rst_n;
  logic                   clear;
  logic                   load;
  logic                   enable;
  logic [DATA_WIDTH-1:0]  data_in;
  logic [ACC_WIDTH-1:0]   load_data;
  logic [ACC_WIDTH-1:0]   acc_out;
  logic                   overflow;

  longint                 ref_total;
  logic                   ref_overflow;

  int unsigned            error_count;
  int unsigned            check_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  accumulator #(
      .DATA_WIDTH (DATA_WIDTH),
      .ACC_WIDTH  (ACC_WIDTH),
      .SIGNED     (SIGNED),
      .SATURATE   (SATURATE)
  ) dut (
      .clk       (clk),
      .rst_n     (rst_n),
      .clear     (clear),
      .load      (load),
      .enable    (enable),
      .data_in   (data_in),
      .load_data (load_data),
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
  function automatic longint decode_addend(input logic [DATA_WIDTH-1:0] value);
    if (SIGNED != 0) begin
      return longint'(signed'(value));
    end else begin
      return longint'({1'b0, value});
    end
  endfunction

  function automatic longint decode_total(input logic [ACC_WIDTH-1:0] value);
    if (SIGNED != 0) begin
      return longint'(signed'(value));
    end else begin
      return longint'({1'b0, value});
    end
  endfunction

  function automatic logic [ACC_WIDTH-1:0] encode_total(input longint value);
    return ACC_WIDTH'(value);
  endfunction

  //---------------------------------------------------------------------------
  // Cycle-accurate reference model.
  //
  // Driven from the same clock as the design and from the control inputs that
  // were applied before the edge, so anything the design does one cycle early
  // or late shows up as a mismatch.
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ref_total    <= 64'd0;
      ref_overflow <= 1'b0;
    end else if (clear) begin
      ref_total    <= 64'd0;
      ref_overflow <= 1'b0;
    end else if (load) begin
      ref_total    <= decode_total(load_data);
      ref_overflow <= 1'b0;
    end else if (enable) begin
      automatic longint sum  = ref_total + decode_addend(data_in);
      automatic logic   over = (SIGNED != 0)
                             ? ((sum > MAX_SIGNED) || (sum < MIN_SIGNED))
                             : ((sum > MAX_UNSIGNED) || (sum < 64'd0));

      ref_overflow <= over;

      if ((SATURATE == 0) || !over) begin
        // Wrap in the accumulator's width, then decode again, so the model
        // follows the design's modular arithmetic exactly.
        ref_total <= decode_total(encode_total(sum));
      end else if (SIGNED != 0) begin
        ref_total <= (sum > MAX_SIGNED) ? MAX_SIGNED : MIN_SIGNED;
      end else begin
        ref_total <= (sum > MAX_UNSIGNED) ? MAX_UNSIGNED : 64'd0;
      end
    end else begin
      ref_overflow <= 1'b0;
    end
  end

  //---------------------------------------------------------------------------
  // Comparison, one cycle after each edge so both sides have settled.
  //---------------------------------------------------------------------------
  task automatic check(input string label);
    #1;
    check_count++;

    if (acc_out !== encode_total(ref_total)) begin
      error_count++;
      $error("%s: acc_out expected 0x%0h, got 0x%0h at time %0t",
             label, encode_total(ref_total), acc_out, $time);
    end
    if (overflow !== ref_overflow) begin
      error_count++;
      $error("%s: overflow expected %0b, got %0b at time %0t",
             label, ref_overflow, overflow, $time);
    end
  endtask

  task automatic step(input logic vclear,
                      input logic vload,
                      input logic venable,
                      input logic [DATA_WIDTH-1:0] vdata,
                      input logic [ACC_WIDTH-1:0]  vload_data,
                      input string label = "step");
    @(negedge clk);
    clear     = vclear;
    load      = vload;
    enable    = venable;
    data_in   = vdata;
    load_data = vload_data;
    @(posedge clk);
    check(label);
  endtask

  task automatic idle_step(input int unsigned count);
    for (int unsigned i = 0; i < count; i++) begin
      step(1'b0, 1'b0, 1'b0, '0, '0, "idle");
    end
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    check_count = 0;
    rst_n       = 1'b0;
    clear       = 1'b0;
    load        = 1'b0;
    enable      = 1'b0;
    data_in     = '0;
    load_data   = '0;

    // --- reset -------------------------------------------------------------
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    check("after reset");

    // --- directed: a running total -----------------------------------------
    for (int unsigned i = 1; i <= 5; i++) begin
      step(1'b0, 1'b0, 1'b1, DATA_WIDTH'(i), '0, "accumulate");
    end

    // --- directed: the total holds and the flag clears ----------------------
    idle_step(5);

    // --- directed: load, then clear ----------------------------------------
    step(1'b0, 1'b1, 1'b0, '0, ACC_WIDTH'('h1234), "load");
    step(1'b0, 1'b0, 1'b1, DATA_WIDTH'(1), '0, "accumulate after load");
    step(1'b1, 1'b0, 1'b0, '0, '0, "clear");

    // --- directed: control priority ----------------------------------------
    step(1'b0, 1'b0, 1'b1, DATA_WIDTH'('h20), '0, "seed");
    step(1'b1, 1'b1, 1'b0, '0, ACC_MASK, "clear beats load");
    step(1'b0, 1'b0, 1'b1, DATA_WIDTH'('h11), '0, "seed");
    step(1'b1, 1'b0, 1'b1, DATA_WIDTH'('h33), '0, "clear beats enable");
    step(1'b0, 1'b1, 1'b1, DATA_WIDTH'('h44), ACC_WIDTH'('h77),
         "load beats enable");
    step(1'b1, 1'b1, 1'b1, DATA_WIDTH'('h55), ACC_WIDTH'('hAA),
         "clear beats everything");

    // --- directed: the saturation limits -----------------------------------
    step(1'b0, 1'b1, 1'b0, '0, encode_total(MAX_SIGNED), "load the top limit");
    for (int unsigned i = 0; i < 4; i++) begin
      step(1'b0, 1'b0, 1'b1, DATA_MASK >> 1, '0, "push past the top");
    end

    step(1'b0, 1'b1, 1'b0, '0, encode_total(MIN_SIGNED),
         "load the bottom limit");
    for (int unsigned i = 0; i < 4; i++) begin
      step(1'b0, 1'b0, 1'b1, {1'b1, {(DATA_WIDTH-1){1'b0}}}, '0,
           "push past the bottom");
    end

    // --- regression: growth beyond the data width --------------------------
    step(1'b1, 1'b0, 1'b0, '0, '0, "clear before the long run");
    for (int unsigned i = 0; i < 512; i++) begin
      step(1'b0, 1'b0, 1'b1, DATA_MASK >> 1, '0, "long accumulation");
    end

    // --- randomised: independent control bits every cycle ------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      step(($urandom_range(0, 19) == 0),       // clear, rarely
           ($urandom_range(0, 11) == 0),       // load, occasionally
           ($urandom_range(0, 9)  != 0),       // enable, mostly
           DATA_WIDTH'($urandom()),
           ACC_WIDTH'($urandom()),
           "random");
    end

    // --- verdict ------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_accumulator (%0d checks, DATA_WIDTH=%0d ACC_WIDTH=%0d %s)",
               check_count, DATA_WIDTH, ACC_WIDTH,
               $sformatf("SIGNED=%0d SATURATE=%0d", SIGNED, SATURATE));
      $finish;
    end else begin
      $display("TEST FAILED: tb_accumulator, %0d error(s) in %0d checks",
               error_count, check_count);
      $fatal(1, "tb_accumulator failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(CLK_PERIOD * 1000000);
    $fatal(1, "tb_accumulator: global timeout");
  end

endmodule

`default_nettype wire
