//=============================================================================
// Testbench   : tb_fir
// Description : Self-checking SystemVerilog testbench for fir.
//
// The Python-free smoke test. A reference model written from the header's
// contract - each product uses the coefficients in force when its sample was
// accepted - keeps its own history of samples and coefficient snapshots, and
// every output is compared against it. Coefficients are reloaded several
// times, once in the middle of a stream; samples arrive with random gaps and
// the sink applies random back-pressure. The full suite lives in
// cocotb/test_fir.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_fir;

  localparam int unsigned TAPS       = 7;
  localparam int unsigned DATA_WIDTH = 10;
  localparam int unsigned COEF_WIDTH = 9;
  localparam int unsigned AW         = $clog2(TAPS);
  localparam int unsigned OUT_WIDTH  = DATA_WIDTH + COEF_WIDTH + AW;
  localparam int unsigned N_SAMPLES  = 6000;
  localparam time         CLK_PERIOD = 10ns;

  logic                         clk;
  logic                         rst_n;
  logic                         coef_wr_en;
  logic [AW-1:0]                coef_addr;
  logic signed [COEF_WIDTH-1:0] coef_data;
  logic                         s_valid, s_ready, m_valid, m_ready;
  logic signed [DATA_WIDTH-1:0] s_data;
  logic signed [OUT_WIDTH-1:0]  m_data;

  // Model state: the coefficients now, and for each of the last TAPS samples
  // the sample and the coefficients it was multiplied by.
  logic signed [COEF_WIDTH-1:0] m_coef [TAPS];
  logic signed [DATA_WIDTH-1:0] hist_x [TAPS];
  logic signed [COEF_WIDTH-1:0] hist_h [TAPS][TAPS];
  logic signed [OUT_WIDTH-1:0]  expected [$];
  int unsigned                  received;

  int unsigned error_count;
  int unsigned check_count;

  fir #(
      .TAPS       (TAPS),
      .DATA_WIDTH (DATA_WIDTH),
      .COEF_WIDTH (COEF_WIDTH)
  ) dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .coef_wr_en (coef_wr_en),
      .coef_addr  (coef_addr),
      .coef_data  (coef_data),
      .s_valid    (s_valid),
      .s_ready    (s_ready),
      .s_data     (s_data),
      .m_valid    (m_valid),
      .m_ready    (m_ready),
      .m_data     (m_data)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  // The model and the output check, clocked like the design.
  always @(posedge clk) begin
    if (rst_n) begin
      if (m_valid && m_ready) begin
        check_count++;
        if (expected.size() == 0) begin
          error_count++;
          $display("ERROR: output with no input");
        end else begin
          automatic logic signed [OUT_WIDTH-1:0] want = expected.pop_front();
          if (m_data !== want) begin
            error_count++;
            $display("ERROR: output %0d is %0d, expected %0d", received, m_data, want);
          end
        end
        received++;
      end
      if (s_valid && s_ready) begin
        automatic longint acc = 0;
        for (int k = TAPS - 1; k > 0; k--) begin
          hist_x[k] = hist_x[k-1];
          for (int j = 0; j < TAPS; j++) hist_h[k][j] = hist_h[k-1][j];
        end
        hist_x[0] = s_data;
        for (int j = 0; j < TAPS; j++) hist_h[0][j] = m_coef[j];
        for (int k = 0; k < TAPS; k++) acc += longint'(hist_h[k][k]) * longint'(hist_x[k]);
        expected.push_back(OUT_WIDTH'(acc));
      end
      if (coef_wr_en && 32'(coef_addr) < TAPS) m_coef[coef_addr] = coef_data;
    end
  end

  task automatic load_coefs();
    for (int k = 0; k < TAPS; k++) begin
      coef_wr_en = 1'b1;
      coef_addr  = AW'(k);
      coef_data  = COEF_WIDTH'($urandom());
      @(posedge clk); #1;
    end
    // One write beyond TAPS, which must be ignored.
    coef_addr = AW'(TAPS);
    coef_data = '1;
    @(posedge clk); #1;
    coef_wr_en = 1'b0;
  endtask

  task automatic stream(input int unsigned n, input int unsigned gap_pct,
                        input int unsigned stall_pct);
    for (int unsigned i = 0; i < n; i++) begin
      while ($urandom_range(0, 99) < gap_pct) begin
        s_valid = 1'b0;
        m_ready = ($urandom_range(0, 99) >= stall_pct);
        @(posedge clk); #1;
      end
      s_valid = 1'b1;
      s_data  = DATA_WIDTH'($urandom());
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
    received    = 0;
    coef_wr_en = 1'b0; coef_addr = '0; coef_data = '0;
    s_valid = 1'b0; s_data = '0; m_ready = 1'b1;
    for (int k = 0; k < TAPS; k++) begin
      m_coef[k] = '0;
      hist_x[k] = '0;
      for (int j = 0; j < TAPS; j++) hist_h[k][j] = '0;
    end
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;

    load_coefs();
    stream(N_SAMPLES / 4, 0, 0);
    load_coefs();
    stream(N_SAMPLES / 4, 30, 30);
    // A reload in the middle of a stream: the model blends exactly as the
    // header says the design does.
    fork
      stream(N_SAMPLES / 4, 10, 20);
      begin repeat (40) @(posedge clk); #1; load_coefs(); end
    join
    load_coefs();
    stream(N_SAMPLES / 4, 50, 50);

    check_count++;
    if (expected.size() != 0) begin
      error_count++;
      $display("ERROR: %0d outputs never arrived", expected.size());
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_fir (%0d checks, TAPS=%0d)", check_count, TAPS);
      $finish;
    end else begin
      $display("TEST FAILED: tb_fir, %0d error(s) in %0d checks", error_count, check_count);
      $fatal(1, "tb_fir failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 400000);
    $fatal(1, "tb_fir: global timeout");
  end

endmodule

`default_nettype wire
