//=============================================================================
// Testbench   : tb_lfsr_rng
// Description : Self-checking SystemVerilog testbench for lfsr_rng.
//
// The Python-free smoke test, and the exhaustive one. Fifteen instances,
// WIDTH = 2 to 16 with one bit per draw, run from reset until their state
// first returns to where it started; each must take exactly 2**WIDTH - 1
// steps, which proves every one of those tap entries maximal. Two more
// instances check the draw arithmetic: WIDTH = 16 with STEPS = 3 must return
// after (2**16 - 1) / 3 draws, and WIDTH = 7 with STEPS = 7 after 127.
//
// A last instance, WIDTH = 20 and STEPS = 5, is compared draw for draw with
// a bit-serial model of b[t] = b[t-20] ^ b[t-17] under random back-pressure
// and random seed loads, the zero seed included. The full suite lives in
// cocotb/test_lfsr_rng.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_lfsr_rng;

  localparam time         CLK_PERIOD = 10ns;
  localparam int unsigned N_PERIOD   = 17;     // instances under the period check

  logic clk;
  logic rst_n;

  int unsigned error_count;
  int unsigned check_count;

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Period checks: each instance runs freely from reset and reports the
  // number of draws until its state first comes back.
  //---------------------------------------------------------------------------
  int unsigned period   [N_PERIOD];
  int unsigned expected [N_PERIOD];
  logic        found    [N_PERIOD];

  for (genvar i = 0; i < 15; i++) begin : g_width
    localparam int unsigned W = i + 2;
    logic         valid;
    logic [0:0]   data;
    logic [W-1:0] start;
    lfsr_rng #(.WIDTH(W), .STEPS(1)) u (
        .clk(clk), .rst_n(rst_n), .seed_load(1'b0), .seed('0),
        .m_valid(valid), .m_ready(1'b1), .m_data(data));
    initial expected[i] = (1 << W) - 1;
    always @(posedge clk) begin
      if (!rst_n) begin
        found[i]  <= 1'b0;
        period[i] <= 0;
        start     <= u.state;
      end else if (valid && !found[i]) begin
        if (period[i] != 0 && u.state == start) found[i] <= 1'b1;
        else period[i] <= period[i] + 1;
      end
    end
  end

  for (genvar i = 15; i < N_PERIOD; i++) begin : g_steps
    localparam int unsigned W = (i == 15) ? 16 : 7;
    localparam int unsigned S = (i == 15) ? 3 : 7;
    logic         valid;
    logic [S-1:0] data;
    logic [W-1:0] start;
    lfsr_rng #(.WIDTH(W), .STEPS(S)) u (
        .clk(clk), .rst_n(rst_n), .seed_load(1'b0), .seed('0),
        .m_valid(valid), .m_ready(1'b1), .m_data(data));
    initial expected[i] = (i == 15) ? 21845 : 127;
    always @(posedge clk) begin
      if (!rst_n) begin
        found[i]  <= 1'b0;
        period[i] <= 0;
        start     <= u.state;
      end else if (valid && !found[i]) begin
        if (period[i] != 0 && u.state == start) found[i] <= 1'b1;
        else period[i] <= period[i] + 1;
      end
    end
  end

  //---------------------------------------------------------------------------
  function automatic logic all_found();
    for (int i = 0; i < N_PERIOD; i++) if (!found[i]) return 1'b0;
    return 1'b1;
  endfunction

  //---------------------------------------------------------------------------
  // Model check: WIDTH = 20, STEPS = 5
  //---------------------------------------------------------------------------
  localparam int unsigned MW = 20;
  localparam int unsigned MS = 5;

  logic          seed_load, m_valid, m_ready;
  logic [MW-1:0] seed;
  logic [MS-1:0] m_data;
  logic [MW-1:0] model;
  int unsigned   draws;

  lfsr_rng #(.WIDTH(MW), .STEPS(MS), .SEED(64'hABCDE)) dut (
      .clk(clk), .rst_n(rst_n), .seed_load(seed_load), .seed(seed),
      .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data));

  function automatic logic [MW-1:0] model_draw(input logic [MW-1:0] s);
    logic [MW-1:0] r = s;
    for (int k = 0; k < MS; k++) r = {r[MW-2:0], r[19] ^ r[16]};
    return r;
  endfunction

  always @(negedge clk) begin
    if (rst_n && m_valid) begin
      check_count++;
      if (m_data !== model[MS-1:0]) begin
        error_count++;
        $display("ERROR: draw %0d is %h, expected %h", draws, m_data, model[MS-1:0]);
      end
    end
  end

  always @(posedge clk) begin
    if (rst_n && m_valid) begin
      if (seed_load)    model <= model_draw(seed == '0 ? MW'(1) : seed);
      else if (m_ready) model <= model_draw(model);
      if (m_ready) draws++;
    end
  end

  initial begin
    error_count = 0;
    check_count = 0;
    draws       = 0;
    seed_load   = 1'b0;
    seed        = '0;
    m_ready     = 1'b0;
    model       = model_draw(MW'(20'hABCDE));
    rst_n       = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;

    // Random back-pressure and occasional reseeding, the zero seed included.
    repeat (40000) begin
      @(posedge clk); #1;
      m_ready   = ($urandom_range(0, 99) < 70);
      seed_load = ($urandom_range(0, 99) < 2);
      seed      = ($urandom_range(0, 9) == 0) ? '0 : MW'($urandom());
    end
    seed_load = 1'b0;
    m_ready   = 1'b1;

    // Let the period instances finish: the longest needs 2**16 - 1 draws.
    while (!all_found()) @(posedge clk);
    @(posedge clk); #1;

    for (int i = 0; i < N_PERIOD; i++) begin
      check_count++;
      if (period[i] != expected[i]) begin
        error_count++;
        $display("ERROR: instance %0d returned after %0d draws, expected %0d",
                 i, period[i], expected[i]);
      end
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_lfsr_rng (%0d checks, %0d periods)", check_count, N_PERIOD);
      $finish;
    end else begin
      $display("TEST FAILED: tb_lfsr_rng, %0d error(s) in %0d checks", error_count, check_count);
      $fatal(1, "tb_lfsr_rng failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 200000);
    $fatal(1, "tb_lfsr_rng: global timeout");
  end

endmodule

`default_nettype wire
