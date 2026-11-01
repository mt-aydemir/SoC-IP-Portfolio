//=============================================================================
// Testbench   : tb_cic
// Description : Self-checking SystemVerilog testbench for cic.
//
// The Python-free smoke test, at DIFF_DELAY=2 (the cocotb suite runs M=1).
// A reference model following the header's register semantics - pipelined
// integrators, decimation on the last integrator's register, combs at the
// output rate, all modulo 2**OUT_WIDTH - runs beside the design, through
// bursts at random rates with random gaps and back-pressure, and a DC burst
// at MAX_RATE whose settled output must equal x * (R*M)**N. The full suite
// lives in cocotb/test_cic.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_cic;

  localparam int unsigned STAGES     = 3;
  localparam int unsigned MAX_RATE   = 8;
  localparam int unsigned DIFF_DELAY = 2;
  localparam int unsigned DATA_WIDTH = 10;
  localparam int unsigned OUT_WIDTH  = DATA_WIDTH + STAGES * $clog2(MAX_RATE * DIFF_DELAY);
  localparam int unsigned RW         = $clog2(MAX_RATE + 1);
  localparam time         CLK_PERIOD = 10ns;

  logic                         clk;
  logic                         rst_n;
  logic [RW-1:0]                rate;
  logic                         s_valid, s_ready, m_valid, m_ready;
  logic signed [DATA_WIDTH-1:0] s_data;
  logic signed [OUT_WIDTH-1:0]  m_data;

  // Model
  logic signed [OUT_WIDTH-1:0] mi [STAGES];
  logic signed [OUT_WIDTH-1:0] md [STAGES][DIFF_DELAY];
  int unsigned                 mphase;
  logic signed [OUT_WIDTH-1:0] expected [$];
  logic signed [OUT_WIDTH-1:0] last_out;

  int unsigned error_count;
  int unsigned check_count;

  cic #(
      .STAGES     (STAGES),
      .MAX_RATE   (MAX_RATE),
      .DIFF_DELAY (DIFF_DELAY),
      .DATA_WIDTH (DATA_WIDTH)
  ) dut (
      .clk     (clk),
      .rst_n   (rst_n),
      .rate    (rate),
      .s_valid (s_valid),
      .s_ready (s_ready),
      .s_data  (s_data),
      .m_valid (m_valid),
      .m_ready (m_ready),
      .m_data  (m_data)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  task automatic model_reset();
    for (int s = 0; s < STAGES; s++) begin
      mi[s] = '0;
      for (int d = 0; d < DIFF_DELAY; d++) md[s][d] = '0;
    end
    mphase = 0;
    expected.delete();
  endtask

  always @(posedge clk) begin
    if (rst_n) begin
      if (m_valid && m_ready) begin
        check_count++;
        if (expected.size() == 0) begin
          error_count++;
          $display("ERROR: output with none due");
        end else begin
          automatic logic signed [OUT_WIDTH-1:0] want = expected.pop_front();
          if (m_data !== want) begin
            error_count++;
            $display("ERROR: output %0d expected %0d (rate %0d)", m_data, want, rate);
          end
        end
        last_out = m_data;
      end
      if (s_valid && s_ready) begin
        automatic logic signed [OUT_WIDTH-1:0] old [STAGES];
        automatic logic due = (mphase + 1 >= 32'(rate));
        if (due) begin
          automatic logic signed [OUT_WIDTH-1:0] c = mi[STAGES-1];
          for (int s = 0; s < STAGES; s++) begin
            automatic logic signed [OUT_WIDTH-1:0] prev = md[s][DIFF_DELAY-1];
            for (int d = DIFF_DELAY - 1; d > 0; d--) md[s][d] = md[s][d-1];
            md[s][0] = c;
            c = c - prev;
          end
          expected.push_back(c);
        end
        for (int s = 0; s < STAGES; s++) old[s] = mi[s];
        mi[0] = old[0] + OUT_WIDTH'(s_data);
        for (int s = 1; s < STAGES; s++) mi[s] = old[s] + old[s-1];
        mphase = due ? 0 : mphase + 1;
      end
    end
  end

  task automatic burst(input int unsigned r, input int unsigned n,
                       input int unsigned gap_pct, input int unsigned stall_pct,
                       input logic dc, input logic signed [DATA_WIDTH-1:0] level);
    rate = RW'(r);
    for (int unsigned i = 0; i < n; i++) begin
      while ($urandom_range(0, 99) < gap_pct) begin
        s_valid = 1'b0;
        m_ready = ($urandom_range(0, 99) >= stall_pct);
        @(posedge clk); #1;
      end
      s_valid = 1'b1;
      s_data  = dc ? level : DATA_WIDTH'($urandom());
      forever begin
        m_ready = ($urandom_range(0, 99) >= stall_pct);
        @(negedge clk);
        if (s_ready) break;
        @(posedge clk); #1;
      end
      @(posedge clk); #1;
    end
    s_valid = 1'b0;
    m_ready = 1'b1;
    repeat (3) begin @(posedge clk); #1; end
  endtask

  initial begin
    error_count = 0;
    check_count = 0;
    rate = RW'(2); s_valid = 1'b0; s_data = '0; m_ready = 1'b1;
    model_reset();
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;

    for (int b = 0; b < 40; b++) begin
      automatic int unsigned r = $urandom_range(1, MAX_RATE);
      burst(r, r * $urandom_range(20, 80), $urandom_range(0, 40), $urandom_range(0, 60),
            1'b0, '0);
    end

    // DC at MAX_RATE, long enough for the integrators to wrap.
    burst(MAX_RATE, MAX_RATE * 100, 0, 0, 1'b1, DATA_WIDTH'(-(1 << (DATA_WIDTH - 1))));
    check_count++;
    if (last_out !== OUT_WIDTH'(-(longint'(1) << (DATA_WIDTH - 1))
                                * (longint'(MAX_RATE * DIFF_DELAY) ** STAGES))) begin
      error_count++;
      $display("ERROR: settled DC output %0d", last_out);
    end

    // A reset in the middle of a burst, then a clean burst.
    fork
      burst(5, 100, 10, 50, 1'b0, '0);
      begin
        repeat (60) @(posedge clk);
        #2 rst_n = 1'b0;
        model_reset();
        @(posedge clk); #1 rst_n = 1'b1;
      end
    join
    model_reset();
    rst_n = 1'b0; @(posedge clk); #1 rst_n = 1'b1;
    burst(3, 300, 20, 20, 1'b0, '0);

    check_count++;
    if (expected.size() != 0) begin
      error_count++;
      $display("ERROR: %0d outputs never arrived", expected.size());
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_cic (%0d checks, STAGES=%0d MAX_RATE=%0d M=%0d)",
               check_count, STAGES, MAX_RATE, DIFF_DELAY);
      $finish;
    end else begin
      $display("TEST FAILED: tb_cic, %0d error(s) in %0d checks", error_count, check_count);
      $fatal(1, "tb_cic failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 400000);
    $fatal(1, "tb_cic: global timeout");
  end

endmodule

`default_nettype wire
