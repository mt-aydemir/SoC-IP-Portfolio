//=============================================================================
// Testbench   : tb_clk_divider
// Description : Self-checking SystemVerilog testbench for clk_divider.
//
// Measures the divided clock directly rather than trusting a model: the high
// and low phase durations are timed with $realtime, which is the only way to
// catch a duty cycle that is wrong by half a source period - exactly the error
// an odd divisor invites.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_clk_divider;

  localparam int unsigned DIVISOR    = 5;      // odd: the harder case
  localparam time         CLK_PERIOD = 10ns;
  localparam int unsigned NUM_PERIODS = 20;

  logic        clk;
  logic        rst_n;
  logic        enable;
  logic        clk_en;
  logic        clk_out;

  int unsigned error_count;
  int unsigned enable_pulses;
  int unsigned pulses_before;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  clk_divider #(
      .DIVISOR (DIVISOR)
  ) dut (
      .clk     (clk),
      .rst_n   (rst_n),
      .enable  (enable),
      .clk_en  (clk_en),
      .clk_out (clk_out)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Count clk_en pulses. One pulse per DIVISOR source cycles is the contract.
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n && clk_en) begin
      enable_pulses++;
    end
  end

  //---------------------------------------------------------------------------
  // Measure the divided clock's high and low phases.
  //---------------------------------------------------------------------------
  real last_rise;
  real last_fall;
  real high_time;
  real low_time;
  int unsigned measured;

  task automatic expect_close(input real actual, input real expected,
                              input string context_name);
    // A picosecond of tolerance absorbs the timescale rounding only.
    if (actual < expected - 0.002 || actual > expected + 0.002) begin
      error_count++;
      $error("%s: expected %.3f ns, measured %.3f ns", context_name, expected, actual);
    end
  endtask

  initial begin
    error_count   = 0;
    enable_pulses = 0;
    measured      = 0;
    rst_n         = 1'b0;
    enable        = 1'b0;

    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);

    // --- disabled: both outputs parked -------------------------------------
    repeat (2 * DIVISOR) @(posedge clk);
    #1;
    if (clk_out !== 1'b0 || clk_en !== 1'b0) begin
      error_count++;
      $error("disabled: clk_out and clk_en must both be low");
    end
    if (enable_pulses != 0) begin
      error_count++;
      $error("disabled: %0d enable pulse(s) were produced", enable_pulses);
    end

    // --- enable and let the divider settle ----------------------------------
    @(negedge clk);
    enable = 1'b1;

    // Skip the first period: it starts from the reset state, so its low phase
    // is not representative.
    @(posedge clk_out);
    @(posedge clk_out);

    // Seed the reference point. The measuring processes below start on the
    // *next* edge, so without this the first high phase would be measured
    // against time zero.
    last_rise = $realtime;

    // --- measure NUM_PERIODS full periods -----------------------------------
    fork
      begin
        forever begin
          @(posedge clk_out);
          last_rise = $realtime;
          if (measured > 0) begin
            low_time = last_rise - last_fall;
            expect_close(low_time, real'(DIVISOR) * real'(CLK_PERIOD) / 2.0,
                         $sformatf("period %0d low phase", measured));
          end
        end
      end
      begin
        forever begin
          @(negedge clk_out);
          last_fall = $realtime;
          high_time = last_fall - last_rise;
          expect_close(high_time, real'(DIVISOR) * real'(CLK_PERIOD) / 2.0,
                       $sformatf("period %0d high phase", measured));
          measured++;
        end
      end
      begin
        wait (measured >= NUM_PERIODS);
      end
    join_any
    disable fork;

    // --- clk_en rate ---------------------------------------------------------
    pulses_before = enable_pulses;
    repeat (10 * DIVISOR) @(posedge clk);
    #1;
    if (enable_pulses - pulses_before != 10) begin
      error_count++;
      $error("clk_en rate: expected 10 pulses in %0d cycles, got %0d",
             10 * DIVISOR, enable_pulses - pulses_before);
    end

    // --- disable parks the outputs again -------------------------------------
    @(negedge clk);
    enable = 1'b0;
    repeat (2 * DIVISOR) @(posedge clk);
    #1;
    if (clk_out !== 1'b0) begin
      error_count++;
      $error("clk_out must park low when the divider is disabled");
    end

    // --- verdict --------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_clk_divider (DIVISOR=%0d, %0d periods measured)",
               DIVISOR, measured);
      $finish;
    end else begin
      $display("TEST FAILED: tb_clk_divider, %0d error(s)", error_count);
      $fatal(1, "tb_clk_divider failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 100000);
    $fatal(1, "tb_clk_divider: global timeout");
  end

endmodule

`default_nettype wire
