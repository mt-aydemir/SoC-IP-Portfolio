//=============================================================================
// Testbench   : tb_reset_controller
// Description : Self-checking SystemVerilog testbench for reset_controller.
//
// Checks the three properties the block promises: all stages assert together
// and immediately, they release in ascending index order, and consecutive
// releases are separated by exactly STAGE_DELAY clock cycles.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_reset_controller;

  localparam int unsigned NUM_STAGES        = 4;
  localparam int unsigned STAGE_DELAY       = 4;
  localparam int unsigned MIN_ASSERT_CYCLES = 16;
  localparam int unsigned SYNC_STAGES       = 3;
  localparam time         CLK_PERIOD        = 10ns;

  logic                  clk;
  logic                  arst_n_in;
  logic                  sw_reset;
  logic [NUM_STAGES-1:0] rst_n_out;
  logic                  reset_active;

  int unsigned           error_count;
  int unsigned           cycle_count;
  int unsigned           release_cycle [NUM_STAGES];

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  reset_controller #(
      .NUM_STAGES        (NUM_STAGES),
      .STAGE_DELAY       (STAGE_DELAY),
      .MIN_ASSERT_CYCLES (MIN_ASSERT_CYCLES),
      .SYNC_STAGES       (SYNC_STAGES)
  ) dut (
      .clk          (clk),
      .arst_n_in    (arst_n_in),
      .sw_reset     (sw_reset),
      .rst_n_out    (rst_n_out),
      .reset_active (reset_active)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Free-running cycle counter, and capture of each stage's release cycle.
  //---------------------------------------------------------------------------
  logic [NUM_STAGES-1:0] rst_n_prev;

  always_ff @(posedge clk) begin
    cycle_count <= cycle_count + 1;
    rst_n_prev  <= rst_n_out;

    for (int unsigned s = 0; s < NUM_STAGES; s++) begin
      if (rst_n_out[s] && !rst_n_prev[s]) begin
        release_cycle[s] <= cycle_count;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Continuous order check: a stage may never be released while a lower
  // numbered stage is still asserted.
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    for (int unsigned s = 1; s < NUM_STAGES; s++) begin
      if (rst_n_out[s] && !rst_n_out[s-1]) begin
        error_count++;
        $error("stage %0d released while stage %0d was still asserted at %0t",
               s, s - 1, $time);
      end
    end
  end

  //---------------------------------------------------------------------------
  // Wait until every stage has released, with a bounded guard.
  //---------------------------------------------------------------------------
  task automatic wait_all_released();
    int unsigned guard;
    guard = 0;
    while (rst_n_out !== {NUM_STAGES{1'b1}} && guard < 1000) begin
      @(posedge clk);
      #1;
      guard++;
    end
    if (rst_n_out !== {NUM_STAGES{1'b1}}) begin
      error_count++;
      $error("not every stage released within %0d cycles (rst_n_out=0x%0h)",
             guard, rst_n_out);
    end
    // The release_cycle[] captures are edge-detected against a registered
    // copy, so they land one cycle after the rise. Let them settle before any
    // caller inspects them.
    repeat (2) @(posedge clk);
    #1;
  endtask

  task automatic check_spacing(input string context_name);
    for (int unsigned s = 1; s < NUM_STAGES; s++) begin
      if (release_cycle[s] - release_cycle[s-1] != STAGE_DELAY) begin
        error_count++;
        $error("%s: stages %0d and %0d are %0d cycles apart, expected %0d",
               context_name, s - 1, s,
               release_cycle[s] - release_cycle[s-1], STAGE_DELAY);
      end
    end
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    cycle_count = 0;
    arst_n_in   = 1'b0;
    sw_reset    = 1'b0;

    // --- all stages asserted while the reset is held -------------------------
    repeat (10) @(posedge clk);
    #1;
    if (rst_n_out !== '0) begin
      error_count++;
      $error("all stages must be asserted while arst_n_in is low (0x%0h)",
             rst_n_out);
    end
    if (reset_active !== 1'b1) begin
      error_count++;
      $error("reset_active must be high while the reset is held");
    end

    // --- release and check the staged sequence -------------------------------
    @(negedge clk);
    arst_n_in = 1'b1;
    wait_all_released();
    check_spacing("power-on release");

    repeat (4) @(posedge clk);
    #1;
    if (reset_active !== 1'b0) begin
      error_count++;
      $error("reset_active must fall once every stage has released");
    end

    // --- a one-cycle software request re-asserts everything -------------------
    @(negedge clk);
    sw_reset = 1'b1;
    @(negedge clk);
    sw_reset = 1'b0;
    #1;
    if (rst_n_out !== '0) begin
      error_count++;
      $error("a software reset must assert every stage (0x%0h)", rst_n_out);
    end

    wait_all_released();
    check_spacing("software reset release");

    // --- the assertion is stretched to at least MIN_ASSERT_CYCLES ------------
    begin
      int unsigned assert_start;
      int unsigned assert_end;

      @(negedge clk);
      assert_start = cycle_count;
      sw_reset = 1'b1;
      @(negedge clk);
      sw_reset = 1'b0;

      while (rst_n_out[0] !== 1'b1) begin
        @(posedge clk);
      end
      assert_end = cycle_count;

      if (assert_end - assert_start < MIN_ASSERT_CYCLES) begin
        error_count++;
        $error("a one-cycle request produced only %0d cycles of reset, minimum is %0d",
               assert_end - assert_start, MIN_ASSERT_CYCLES);
      end
      wait_all_released();
    end

    // --- asynchronous assertion away from a clock edge ------------------------
    @(posedge clk);
    #(CLK_PERIOD / 3) arst_n_in = 1'b0;
    #1;
    if (rst_n_out !== '0) begin
      error_count++;
      $error("asynchronous assertion must take effect without a clock edge");
    end

    @(negedge clk);
    arst_n_in = 1'b1;
    wait_all_released();
    check_spacing("asynchronous re-assertion");

    // --- repeated software resets back to back --------------------------------
    for (int unsigned i = 0; i < 10; i++) begin
      @(negedge clk);
      sw_reset = 1'b1;
      repeat ($urandom_range(1, 3)) @(negedge clk);
      sw_reset = 1'b0;
      wait_all_released();
      check_spacing($sformatf("repeat %0d", i));
    end

    // --- verdict --------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_reset_controller (%0d stages, %0d cycle spacing)",
               NUM_STAGES, STAGE_DELAY);
      $finish;
    end else begin
      $display("TEST FAILED: tb_reset_controller, %0d error(s)", error_count);
      $fatal(1, "tb_reset_controller failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 200000);
    $fatal(1, "tb_reset_controller: global timeout");
  end

endmodule

`default_nettype wire
