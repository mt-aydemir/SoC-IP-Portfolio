//=============================================================================
// Testbench   : tb_iir
// Description : Self-checking SystemVerilog testbench for iir.
//
// The Python-free smoke test. Two instances share one stimulus stream: one
// with fractional coefficients (rounding in play) and one with COEF_FRAC = 0
// (no rounding stage at all). Each has its own reference model, written from
// the header: five products summed exactly, rounded half up, saturated, and
// the saturated value fed back. Coefficients are reloaded between bursts,
// including unstable sets that drive the outputs into saturation. The full
// suite lives in cocotb/test_iir.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_iir;

  localparam int unsigned DATA_WIDTH = 14;
  localparam int unsigned COEF_WIDTH = 16;
  localparam int unsigned FRAC [2]   = '{14, 0};
  localparam time         CLK_PERIOD = 10ns;

  logic                         clk;
  logic                         rst_n;
  logic                         coef_wr_en;
  logic [2:0]                   coef_addr;
  logic signed [COEF_WIDTH-1:0] coef_data;
  logic                         s_valid, m_ready;
  logic signed [DATA_WIDTH-1:0] s_data;
  logic [1:0]                   s_ready, m_valid, m_saturated;
  logic signed [DATA_WIDTH-1:0] m_data [2];

  // Models
  longint mc [2][5];
  longint mx1 [2], mx2 [2], my1 [2], my2 [2];
  longint exp_y [2][$];
  logic   exp_s [2][$];
  int unsigned saturations;

  int unsigned error_count;
  int unsigned check_count;

  for (genvar i = 0; i < 2; i++) begin : g_dut
    iir #(
        .DATA_WIDTH (DATA_WIDTH),
        .COEF_WIDTH (COEF_WIDTH),
        .COEF_FRAC  (FRAC[i])
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .coef_wr_en  (coef_wr_en),
        .coef_addr   (coef_addr),
        .coef_data   (coef_data),
        .s_valid     (s_valid),
        .s_ready     (s_ready[i]),
        .s_data      (s_data),
        .m_valid     (m_valid[i]),
        .m_ready     (m_ready),
        .m_data      (m_data[i]),
        .m_saturated (m_saturated[i])
    );
  end

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  always @(posedge clk) begin
    if (rst_n) begin
      for (int i = 0; i < 2; i++) begin
        if (m_valid[i] && m_ready) begin
          check_count++;
          if (exp_y[i].size() == 0) begin
            error_count++;
            $display("ERROR: instance %0d output with no input", i);
          end else begin
            automatic longint want = exp_y[i].pop_front();
            automatic logic   want_s = exp_s[i].pop_front();
            if (longint'(m_data[i]) != want || m_saturated[i] !== want_s) begin
              error_count++;
              $display("ERROR: instance %0d output %0d/%b expected %0d/%b",
                       i, m_data[i], m_saturated[i], want, want_s);
            end
          end
        end
        if (s_valid && s_ready[i]) begin
          automatic longint acc = mc[i][0] * longint'(s_data) + mc[i][1] * mx1[i]
                                + mc[i][2] * mx2[i] - mc[i][3] * my1[i] - mc[i][4] * my2[i];
          automatic longint q, y;
          if (FRAC[i] > 0) acc += longint'(1) << (FRAC[i] - 1);
          q = acc >>> FRAC[i];
          y = (q > (longint'(1) << (DATA_WIDTH - 1)) - 1) ? (longint'(1) << (DATA_WIDTH - 1)) - 1
            : (q < -(longint'(1) << (DATA_WIDTH - 1))) ? -(longint'(1) << (DATA_WIDTH - 1)) : q;
          exp_y[i].push_back(y);
          exp_s[i].push_back(q != y);
          if (q != y) saturations++;
          mx2[i] = mx1[i]; mx1[i] = longint'(s_data);
          my2[i] = my1[i]; my1[i] = y;
        end
        if (coef_wr_en && coef_addr < 3'd5) mc[i][coef_addr] = longint'(coef_data);
      end
    end
  end

  task automatic load(input int unsigned scale_pct);
    for (int k = 0; k < 5; k++) begin
      automatic int c = $signed(COEF_WIDTH'($urandom()));
      coef_wr_en = 1'b1;
      coef_addr  = 3'(k);
      coef_data  = COEF_WIDTH'(c * int'(scale_pct) / 100);
      @(posedge clk); #1;
    end
    coef_addr = 3'd6;                     // ignored
    coef_data = '1;
    @(posedge clk); #1;
    coef_wr_en = 1'b0;
  endtask

  task automatic burst(input int unsigned n, input int unsigned gap_pct,
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
        if (s_ready[0]) break;
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
    saturations = 0;
    coef_wr_en = 1'b0; coef_addr = '0; coef_data = '0;
    s_valid = 1'b0; s_data = '0; m_ready = 1'b1;
    for (int i = 0; i < 2; i++) begin
      for (int k = 0; k < 5; k++) mc[i][k] = 0;
      mx1[i] = 0; mx2[i] = 0; my1[i] = 0; my2[i] = 0;
    end
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;

    for (int b = 0; b < 24; b++) begin
      load((b % 3 == 0) ? 100 : 30);
      burst(250, $urandom_range(0, 40), $urandom_range(0, 50));
    end

    check_count++;
    if (s_ready[0] !== s_ready[1] || exp_y[0].size() != 0 || exp_y[1].size() != 0) begin
      error_count++;
      $display("ERROR: instances out of step or outputs missing");
    end
    check_count++;
    if (saturations == 0) begin
      error_count++;
      $display("ERROR: saturation was never exercised");
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_iir (%0d checks, %0d saturated outputs)",
               check_count, saturations);
      $finish;
    end else begin
      $display("TEST FAILED: tb_iir, %0d error(s) in %0d checks", error_count, check_count);
      $fatal(1, "tb_iir failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 400000);
    $fatal(1, "tb_iir: global timeout");
  end

endmodule

`default_nettype wire
