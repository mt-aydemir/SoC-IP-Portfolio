//=============================================================================
// Testbench   : tb_requant_int8
// Description : Self-checking SystemVerilog testbench for requant_int8.
//
// The block's whole value is that it is bit-exact, so the reference here is a
// 64-bit model of the specified arithmetic and every check is an equality.
// It covers the rounding ties, both clamp edges, a shift of zero and a long
// randomised run with the parameters changing on every beat.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_requant_int8;

  localparam int unsigned ACC_WIDTH   = 32;
  localparam int unsigned MULT_WIDTH  = 24;
  localparam int unsigned SHIFT_WIDTH = 6;
  localparam int unsigned OUT_WIDTH   = 8;
  localparam int unsigned LATENCY     = 3;
  localparam time         CLK_PERIOD  = 4ns;
  localparam int unsigned NUM_RANDOM  = 3000;

  // The rounding term must stay inside the product width, which is what the
  // RTL asserts; the model would otherwise be exercising an illegal input.
  localparam int unsigned PROD_WIDTH = ACC_WIDTH + 1 + MULT_WIDTH + 1;
  localparam int unsigned MAX_SHIFT  = (PROD_WIDTH - 1 < (2 ** SHIFT_WIDTH) - 1)
                                     ? PROD_WIDTH - 1 : (2 ** SHIFT_WIDTH) - 1;

  localparam int signed OUT_LOW  = -(2 ** (OUT_WIDTH - 1));
  localparam int signed OUT_HIGH = (2 ** (OUT_WIDTH - 1)) - 1;

  logic                          clk;
  logic                          rst_n;
  logic                          in_valid;
  logic signed [ACC_WIDTH-1:0]   acc;
  logic signed [ACC_WIDTH-1:0]   bias;
  logic        [MULT_WIDTH-1:0]  mult;
  logic        [SHIFT_WIDTH-1:0] shift;
  logic signed [OUT_WIDTH-1:0]   out_zero_point;
  logic signed [OUT_WIDTH-1:0]   out_min;
  logic signed [OUT_WIDTH-1:0]   out_max;
  logic                          out_valid;
  logic signed [OUT_WIDTH-1:0]   out_data;
  logic                          saturated;

  int unsigned error_count;
  int unsigned check_count;

  requant_int8 #(
      .ACC_WIDTH   (ACC_WIDTH),
      .MULT_WIDTH  (MULT_WIDTH),
      .SHIFT_WIDTH (SHIFT_WIDTH),
      .OUT_WIDTH   (OUT_WIDTH)
  ) dut (
      .clk            (clk),
      .rst_n          (rst_n),
      .in_valid       (in_valid),
      .acc            (acc),
      .bias           (bias),
      .mult           (mult),
      .shift          (shift),
      .out_zero_point (out_zero_point),
      .out_min        (out_min),
      .out_max        (out_max),
      .out_valid      (out_valid),
      .out_data       (out_data),
      .saturated      (saturated)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Reference model.
  //
  // Everything is evaluated in 64 bits, which is wider than the widest product
  // the block can form, so the model never wraps where the hardware does not.
  //---------------------------------------------------------------------------
  function automatic longint signed model(
      input longint signed acc_v,
      input longint signed bias_v,
      input longint signed mult_v,
      input int unsigned   shift_v,
      input longint signed zero_point_v,
      input longint signed low_v,
      input longint signed high_v);
    longint signed product;
    longint signed half;
    longint signed adjust;
    longint signed value;

    product = (acc_v + bias_v) * mult_v;
    if (shift_v == 0) begin
      adjust = 0;
    end else begin
      half   = longint'(1) <<< (shift_v - 1);
      adjust = (product < 0) ? half - 1 : half;
    end

    value = ((product + adjust) >>> shift_v) + zero_point_v;
    if (value < low_v)  return low_v;
    if (value > high_v) return high_v;
    return value;
  endfunction

  //---------------------------------------------------------------------------
  // Expectation queue. One entry is pushed per accepted input and popped by
  // the monitor when the corresponding result appears.
  //---------------------------------------------------------------------------
  typedef struct {
    longint signed expected;
    bit            saturates;
    longint signed acc_v;
    longint signed mult_v;
    int unsigned   shift_v;
  } expect_t;

  expect_t pending [$];

  task automatic apply(input longint signed acc_v,
                       input longint signed bias_v,
                       input longint signed mult_v,
                       input int unsigned   shift_v,
                       input longint signed zero_point_v,
                       input longint signed low_v,
                       input longint signed high_v);
    expect_t entry;
    longint signed raw;

    @(negedge clk);
    in_valid       = 1'b1;
    acc            = ACC_WIDTH'(acc_v);
    bias           = ACC_WIDTH'(bias_v);
    mult           = MULT_WIDTH'(mult_v);
    shift          = SHIFT_WIDTH'(shift_v);
    out_zero_point = OUT_WIDTH'(zero_point_v);
    out_min        = OUT_WIDTH'(low_v);
    out_max        = OUT_WIDTH'(high_v);

    raw = model(acc_v, bias_v, mult_v, shift_v, zero_point_v,
                longint'(-(2 ** 62)), longint'(2 ** 62));
    entry.expected  = model(acc_v, bias_v, mult_v, shift_v, zero_point_v,
                            low_v, high_v);
    entry.saturates = (raw != entry.expected);
    entry.acc_v     = acc_v;
    entry.mult_v    = mult_v;
    entry.shift_v   = shift_v;
    pending.push_back(entry);
  endtask

  task automatic idle_cycle();
    @(negedge clk);
    in_valid = 1'b0;
  endtask

  //---------------------------------------------------------------------------
  // Monitor
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n && out_valid) begin
      if (pending.size() == 0) begin
        error_count++;
        $error("result %0d appeared with nothing outstanding at %0t",
               out_data, $time);
      end else begin
        automatic expect_t entry = pending.pop_front();
        check_count++;
        if (out_data !== OUT_WIDTH'(entry.expected)) begin
          error_count++;
          $error({"requantise(acc=%0d, mult=%0d, shift=%0d): expected %0d, ",
                  "got %0d at %0t"},
                 entry.acc_v, entry.mult_v, entry.shift_v, entry.expected,
                 out_data, $time);
        end
        if (saturated !== entry.saturates) begin
          error_count++;
          $error("saturated flag: expected %0b, got %0b at %0t",
                 entry.saturates, saturated, $time);
        end
      end
    end
  end

  initial begin
    longint signed acc_v;
    longint signed bias_v;
    longint signed mult_v;
    int unsigned   shift_v;

    error_count    = 0;
    check_count    = 0;
    rst_n          = 1'b0;
    in_valid       = 1'b0;
    acc            = '0;
    bias           = '0;
    mult           = MULT_WIDTH'(1);
    shift          = '0;
    out_zero_point = '0;
    out_min        = OUT_WIDTH'(OUT_LOW);
    out_max        = OUT_WIDTH'(OUT_HIGH);

    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    #1;

    // --- reset state ---------------------------------------------------------
    if (out_valid !== 1'b0 || out_data !== '0 || saturated !== 1'b0) begin
      error_count++;
      $error("reset state wrong: out_valid=%0b out_data=%0d saturated=%0b",
             out_valid, out_data, saturated);
    end

    // --- rounding ties, both signs -------------------------------------------
    apply(3, 0, 1, 1, 0, OUT_LOW, OUT_HIGH);    //  1.5 ->  2
    apply(-3, 0, 1, 1, 0, OUT_LOW, OUT_HIGH);   // -1.5 -> -2
    apply(1, 0, 1, 1, 0, OUT_LOW, OUT_HIGH);    //  0.5 ->  1
    apply(-1, 0, 1, 1, 0, OUT_LOW, OUT_HIGH);   // -0.5 -> -1
    apply(6, 0, 1, 2, 0, OUT_LOW, OUT_HIGH);    //  1.5 ->  2
    apply(-6, 0, 1, 2, 0, OUT_LOW, OUT_HIGH);   // -1.5 -> -2

    // --- shift of zero is the identity ---------------------------------------
    apply(0, 0, 1, 0, 0, OUT_LOW, OUT_HIGH);
    apply(-1, 0, 1, 0, 0, OUT_LOW, OUT_HIGH);
    apply(1, 0, 1, 0, 0, OUT_LOW, OUT_HIGH);

    // --- clamp edges ---------------------------------------------------------
    apply(1 << 20, 0, 1, 0, 0, OUT_LOW, OUT_HIGH);
    apply(-(1 << 20), 0, 1, 0, 0, OUT_LOW, OUT_HIGH);
    apply(OUT_HIGH, 0, 1, 0, 0, OUT_LOW, OUT_HIGH);
    apply(OUT_LOW, 0, 1, 0, 0, OUT_LOW, OUT_HIGH);

    // --- a fused ReLU is the window, not a mode ------------------------------
    apply(-1000, 0, 1, 0, -5, -5, OUT_HIGH);
    apply(1000, 0, 1, 0, -5, -5, 20);

    // --- randomised, parameters changing on every beat -----------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      acc_v   = longint'($signed({$urandom(), $urandom()})) % (1 << 24);
      bias_v  = longint'($signed($urandom())) % (1 << 18);
      mult_v  = longint'($urandom_range(0, (2 ** MULT_WIDTH) - 1));
      shift_v = $urandom_range(0, MAX_SHIFT);
      apply(acc_v, bias_v, mult_v, shift_v,
            longint'($urandom_range(0, 40)) - 20, OUT_LOW, OUT_HIGH);
    end

    // --- a gap in the stream must produce a gap in the results ---------------
    idle_cycle();
    idle_cycle();
    apply(64, 0, 1, 1, 0, OUT_LOW, OUT_HIGH);
    idle_cycle();

    repeat (LATENCY + 8) @(posedge clk);

    // --- verdict -------------------------------------------------------------
    if (pending.size() != 0) begin
      error_count++;
      $error("%0d input(s) never produced a result", pending.size());
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_requant_int8 (%0d checks)", check_count);
      $finish;
    end else begin
      $display("TEST FAILED: tb_requant_int8, %0d error(s)", error_count);
      $fatal(1, "tb_requant_int8 failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 500000);
    $fatal(1, "tb_requant_int8: global timeout");
  end

endmodule

`default_nettype wire
