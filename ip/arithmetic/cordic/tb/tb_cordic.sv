//=============================================================================
// Testbench   : tb_cordic
// Description : Self-checking SystemVerilog testbench for cordic.
//
// The Python-free smoke test. It runs on any SystemVerilog simulator, which
// makes it the fastest signal during development and the fallback when cocotb
// is not available. The exhaustive directed, randomised and regression suites
// live in cocotb/test_cordic.py.
//
// The reference is the simulator's own real-valued $sin, $cos, $atan2 and
// $sqrt, and the comparison is an absolute error bound in LSBs rather than an
// exact match. CORDIC is an approximation that gains roughly one bit per
// iteration and rounds at every step; demanding an exact result would test a
// reference implementation's rounding rather than the design.
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

module tb_cordic;

  localparam int unsigned WIDTH         = 16;
  localparam int unsigned ITERATIONS    = 16;
  localparam time         CLK_PERIOD    = 10ns;
  localparam int unsigned NUM_RANDOM    = 400;
  localparam int          TOLERANCE_LSB = 14;

  localparam real PI          = 3.14159265358979323846;
  localparam real CORDIC_GAIN = 1.6467602581210654;
  localparam real DATA_ONE    = real'(1 << (WIDTH - 2));   // Q(WIDTH-2)
  localparam real ANGLE_PI    = real'(1 << (WIDTH - 1));   // pi in angle units

  logic                    clk;
  logic                    rst_n;
  logic                    s_valid;
  logic                    s_ready;
  logic                    mode_vectoring;
  logic signed [WIDTH-1:0] x_in;
  logic signed [WIDTH-1:0] y_in;
  logic signed [WIDTH-1:0] z_in;
  logic                    m_valid;
  logic                    m_ready;
  logic signed [WIDTH-1:0] x_out;
  logic signed [WIDTH-1:0] y_out;
  logic signed [WIDTH-1:0] z_out;
  logic                    out_of_range;

  int unsigned             error_count;
  int unsigned             check_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  cordic #(
      .WIDTH      (WIDTH),
      .ITERATIONS (ITERATIONS)
  ) dut (
      .clk            (clk),
      .rst_n          (rst_n),
      .s_valid        (s_valid),
      .s_ready        (s_ready),
      .mode_vectoring (mode_vectoring),
      .x_in           (x_in),
      .y_in           (y_in),
      .z_in           (z_in),
      .m_valid        (m_valid),
      .m_ready        (m_ready),
      .x_out          (x_out),
      .y_out          (y_out),
      .z_out          (z_out),
      .out_of_range   (out_of_range)
  );

  //---------------------------------------------------------------------------
  // Clock
  //---------------------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Format conversion
  //---------------------------------------------------------------------------
  function automatic logic signed [WIDTH-1:0] to_angle(input real radians);
    return WIDTH'($rtoi(radians / PI * ANGLE_PI + ((radians >= 0.0) ? 0.5 : -0.5)));
  endfunction

  function automatic logic signed [WIDTH-1:0] to_data(input real value);
    return WIDTH'($rtoi(value * DATA_ONE + ((value >= 0.0) ? 0.5 : -0.5)));
  endfunction

  function automatic int abs_int(input int value);
    return (value < 0) ? -value : value;
  endfunction

  //---------------------------------------------------------------------------
  // One operation through the ready/valid interfaces
  //---------------------------------------------------------------------------
  task automatic operate(input logic                    vmode,
                         input logic signed [WIDTH-1:0] vx,
                         input logic signed [WIDTH-1:0] vy,
                         input logic signed [WIDTH-1:0] vz);
    int unsigned waited;

    @(negedge clk);
    mode_vectoring = vmode;
    x_in           = vx;
    y_in           = vy;
    z_in           = vz;
    s_valid        = 1'b1;
    do begin
      @(posedge clk);
    end while (s_ready !== 1'b1);
    @(negedge clk);
    s_valid = 1'b0;

    waited = 0;
    while (m_valid !== 1'b1) begin
      @(negedge clk);
      waited++;
      if (waited > ITERATIONS + 8) begin
        error_count++;
        $error("cordic: no result after %0d cycles", waited);
        return;
      end
    end
  endtask

  task automatic expect_near(input string                   label,
                             input logic signed [WIDTH-1:0] got,
                             input logic signed [WIDTH-1:0] want);
    check_count++;
    if (abs_int(int'(got) - int'(want)) > TOLERANCE_LSB) begin
      error_count++;
      $error("%s: expected %0d, got %0d (error %0d LSB, tolerance %0d)",
             label, want, got, int'(got) - int'(want), TOLERANCE_LSB);
    end
  endtask

  //---------------------------------------------------------------------------
  // Rotation: start from (1/K, 0) so the gain lands the result at unit
  // amplitude, and expect (cos z, sin z).
  //---------------------------------------------------------------------------
  task automatic check_rotation(input real radians);
    operate(1'b0, to_data(1.0 / CORDIC_GAIN), '0, to_angle(radians));
    expect_near($sformatf("cos(%f)", radians), x_out, to_data($cos(radians)));
    expect_near($sformatf("sin(%f)", radians), y_out, to_data($sin(radians)));
    if (out_of_range !== 1'b0) begin
      error_count++;
      $error("rotation by %f rad flagged out of range", radians);
    end
  endtask

  //---------------------------------------------------------------------------
  // Vectoring: expect (K * magnitude, 0, atan2(y, x)). Only the right half
  // plane converges, so x is kept positive.
  //---------------------------------------------------------------------------
  task automatic check_vectoring(input real vx, input real vy);
    operate(1'b1, to_data(vx), to_data(vy), '0);
    expect_near($sformatf("|(%f,%f)|", vx, vy), x_out,
                to_data(CORDIC_GAIN * $sqrt(vx * vx + vy * vy)));
    expect_near($sformatf("y residue (%f,%f)", vx, vy), y_out, '0);
    expect_near($sformatf("atan2(%f,%f)", vy, vx), z_out,
                to_angle($atan2(vy, vx)));
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count    = 0;
    check_count    = 0;
    rst_n          = 1'b0;
    s_valid        = 1'b0;
    mode_vectoring = 1'b0;
    x_in           = '0;
    y_in           = '0;
    z_in           = '0;
    m_ready        = 1'b1;

    // --- reset -------------------------------------------------------------
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    #1;
    if (m_valid !== 1'b0 || s_ready !== 1'b1) begin
      error_count++;
      $error("reset: expected m_valid=0 s_ready=1, got %0b %0b", m_valid, s_ready);
    end

    // --- directed: rotation at the cardinal and familiar angles -------------
    check_rotation(0.0);
    check_rotation(PI / 6.0);
    check_rotation(PI / 4.0);
    check_rotation(PI / 3.0);
    check_rotation(PI / 2.0);
    check_rotation(-PI / 4.0);
    check_rotation(-PI / 2.0);

    // --- directed: vectoring on known vectors -------------------------------
    check_vectoring(0.5, 0.0);
    check_vectoring(0.3, 0.4);       // the 3-4-5 triangle
    check_vectoring(0.4, -0.3);
    check_vectoring(0.25, 0.25);

    // --- directed: the convergence-range flag -------------------------------
    operate(1'b0, to_data(0.5), '0, to_angle(0.9 * PI));
    check_count++;
    if (out_of_range !== 1'b1) begin
      error_count++;
      $error("rotation by 0.9*pi was not flagged out of range");
    end
    operate(1'b0, to_data(0.5), '0, to_angle(-0.9 * PI));
    check_count++;
    if (out_of_range !== 1'b1) begin
      error_count++;
      $error("rotation by -0.9*pi was not flagged out of range");
    end

    // --- randomised: rotation across the convergence range ------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      real radians;
      radians = (real'($urandom_range(0, 20000)) / 10000.0 - 1.0) * (PI / 2.0);
      check_rotation(radians);
    end

    // --- randomised: vectoring in the right half plane ----------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      real vx;
      real vy;
      vx = real'($urandom_range(500, 7000)) / 10000.0;
      vy = real'($urandom_range(0, 14000)) / 10000.0 - 0.7;
      check_vectoring(vx, vy);
    end

    // --- verdict ------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_cordic (%0d checks, WIDTH=%0d ITERATIONS=%0d)",
               check_count, WIDTH, ITERATIONS);
      $finish;
    end else begin
      $display("TEST FAILED: tb_cordic, %0d error(s) in %0d checks",
               error_count, check_count);
      $fatal(1, "tb_cordic failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(CLK_PERIOD * 1000000);
    $fatal(1, "tb_cordic: global timeout");
  end

endmodule

`default_nettype wire
