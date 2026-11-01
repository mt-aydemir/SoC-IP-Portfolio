//=============================================================================
// Testbench   : tb_fft
// Description : Self-checking SystemVerilog testbench for fft.
//
// The Python-free smoke test, with a reference of its own: a direct
// O(N**2) DFT in real arithmetic, scaled by 1/N - no butterflies, no bit
// reversal, no twiddle ROM - against which every output bin must agree
// within a rounding bound. Frames are random, forward and inverse, with input
// gaps and output back-pressure; every frame is also checked for m_last on
// bin N-1 alone and, under no back-pressure, for the documented cycle count.
// The bit-exact suite lives in cocotb/test_fft.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_fft;

  localparam int unsigned N_LOG2     = 4;
  localparam int unsigned N          = 1 << N_LOG2;
  localparam int unsigned DATA_WIDTH = 10;
  localparam int unsigned FRAMES     = 120;
  localparam real         BOUND      = N_LOG2 / 2.0 + 2.0;
  localparam real         PI         = 3.14159265358979323846;
  localparam time         CLK_PERIOD = 10ns;

  logic                         clk;
  logic                         rst_n;
  logic                         s_valid, s_ready, inverse;
  logic signed [DATA_WIDTH-1:0] s_re, s_im;
  logic                         m_valid, m_ready, m_last, m_overflow;
  logic signed [DATA_WIDTH-1:0] m_re, m_im;

  int x_re [N];
  int x_im [N];

  int unsigned error_count;
  int unsigned check_count;
  real         worst;

  fft #(
      .N_LOG2     (N_LOG2),
      .DATA_WIDTH (DATA_WIDTH)
  ) dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .s_valid    (s_valid),
      .s_ready    (s_ready),
      .s_re       (s_re),
      .s_im       (s_im),
      .inverse    (inverse),
      .m_valid    (m_valid),
      .m_ready    (m_ready),
      .m_re       (m_re),
      .m_im       (m_im),
      .m_last     (m_last),
      .m_overflow (m_overflow)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  task automatic fail(input string msg);
    error_count++;
    $display("ERROR: %s", msg);
  endtask

  task automatic frame(input logic inv, input int unsigned gap_pct,
                       input int unsigned stall_pct, input int unsigned amp);
    automatic int unsigned start;
    automatic real ref_re [N];
    automatic real ref_im [N];

    for (int n = 0; n < N; n++) begin
      x_re[n] = $urandom_range(0, 2 * amp) - int'(amp);
      x_im[n] = $urandom_range(0, 2 * amp) - int'(amp);
    end
    for (int k = 0; k < N; k++) begin
      ref_re[k] = 0.0;
      ref_im[k] = 0.0;
      for (int n = 0; n < N; n++) begin
        automatic real ang = (inv ? 2.0 : -2.0) * PI * real'(n * k) / real'(N);
        ref_re[k] += (real'(x_re[n]) * $cos(ang) - real'(x_im[n]) * $sin(ang)) / real'(N);
        ref_im[k] += (real'(x_re[n]) * $sin(ang) + real'(x_im[n]) * $cos(ang)) / real'(N);
      end
    end

    start = $time / CLK_PERIOD;
    for (int n = 0; n < N; n++) begin
      while ($urandom_range(0, 99) < gap_pct) begin
        s_valid = 1'b0;
        @(posedge clk); #1;
      end
      s_valid = 1'b1;
      s_re    = DATA_WIDTH'(x_re[n]);
      s_im    = DATA_WIDTH'(x_im[n]);
      inverse = inv;
      forever begin
        @(negedge clk);
        if (s_ready) break;
        @(posedge clk); #1;
      end
      @(posedge clk); #1;
    end
    s_valid = 1'b0;

    for (int k = 0; k < N; k++) begin
      automatic real dr, di;
      forever begin
        m_ready = ($urandom_range(0, 99) >= stall_pct);
        @(negedge clk);
        if (m_valid && m_ready) break;
        @(posedge clk); #1;
      end
      dr = real'(m_re) - ref_re[k];
      di = real'(m_im) - ref_im[k];
      if (dr < 0) dr = -dr;
      if (di < 0) di = -di;
      if (dr > worst) worst = dr;
      if (di > worst) worst = di;
      check_count += 2;
      if (dr > BOUND || di > BOUND) begin
        fail($sformatf("%s bin %0d: (%0d, %0d), DFT (%.2f, %.2f)", inv ? "inverse" : "forward",
                       k, m_re, m_im, ref_re[k], ref_im[k]));
      end
      check_count++;
      if (m_last !== (k == N - 1)) fail($sformatf("m_last %b at bin %0d", m_last, k));
      check_count++;
      if (m_overflow !== 1'b0) fail($sformatf("m_overflow at amplitude %0d", amp));
      @(posedge clk); #1;
    end
    m_ready = 1'b1;

    if (gap_pct == 0 && stall_pct == 0) begin
      check_count++;
      if ($time / CLK_PERIOD - start != 2 * N + (N / 2) * N_LOG2) begin
        fail($sformatf("frame took %0d cycles, expected %0d", $time / CLK_PERIOD - start,
                       2 * N + (N / 2) * N_LOG2));
      end
    end
  endtask

  initial begin
    error_count = 0;
    check_count = 0;
    worst = 0.0;
    s_valid = 1'b0; s_re = '0; s_im = '0; inverse = 1'b0; m_ready = 1'b1;
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk); #1;

    for (int f = 0; f < FRAMES; f++) begin
      // Amplitudes up to 0.4 of full scale cannot saturate a butterfly.
      frame(1'(f % 2), (f % 3 == 0) ? 0 : 20, (f % 3 == 0) ? 0 : 40,
            $urandom_range(1, (2 ** (DATA_WIDTH - 1)) * 4 / 10));
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_fft (%0d checks, N=%0d, worst %.2f LSB from the DFT)",
               check_count, N, worst);
      $finish;
    end else begin
      $display("TEST FAILED: tb_fft, %0d error(s) in %0d checks", error_count, check_count);
      $fatal(1, "tb_fft failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 400000);
    $fatal(1, "tb_fft: global timeout");
  end

endmodule

`default_nettype wire
