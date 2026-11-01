//=============================================================================
// Testbench   : tb_spi_master
// Description : Self-checking SystemVerilog testbench for spi_master.
//
// The Python-free smoke test, at a 12-bit word so the geometry differs from
// the cocotb suite. mosi is echoed back on miso, so every word must come
// back unchanged, in every mode and both bit orders. An edge counter
// checks that each word is exactly 2 * DATA_WIDTH SCLK edges and that SCLK
// is at cpol whenever the slave is deselected. The full suites live in
// cocotb/test_spi_master.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_spi_master;

  localparam int unsigned DATA_WIDTH = 12;
  localparam int unsigned DIV_WIDTH  = 4;
  localparam time         CLK_PERIOD = 10ns;

  logic                  clk;
  logic                  rst_n;
  logic                  cpol;
  logic                  cpha;
  logic                  lsb_first;
  logic [DIV_WIDTH-1:0]  clk_div;
  logic                  s_valid;
  logic                  s_ready;
  logic [DATA_WIDTH-1:0] s_data;
  logic                  s_last;
  logic                  m_valid;
  logic [DATA_WIDTH-1:0] m_data;
  logic                  busy;
  logic                  sclk;
  logic                  mosi;
  logic                  miso;
  logic                  cs_n;

  int unsigned error_count;
  int unsigned check_count;

  spi_master #(
      .DATA_WIDTH (DATA_WIDTH),
      .DIV_WIDTH  (DIV_WIDTH)
  ) dut (
      .clk       (clk),
      .rst_n     (rst_n),
      .cpol      (cpol),
      .cpha      (cpha),
      .lsb_first (lsb_first),
      .clk_div   (clk_div),
      .s_valid   (s_valid),
      .s_ready   (s_ready),
      .s_data    (s_data),
      .s_last    (s_last),
      .m_valid   (m_valid),
      .m_data    (m_data),
      .busy      (busy),
      .sclk      (sclk),
      .mosi      (mosi),
      .miso      (miso),
      .cs_n      (cs_n)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Echo slave. A real slave cannot return a bit before it has sampled it,
  // but mosi changes only on shift edges and the master samples miso half a
  // period later, so an echo is a valid miso in every mode and makes the
  // expected word the word sent. The cocotb suite has a real slave model.
  //---------------------------------------------------------------------------
  assign miso = mosi;

  //---------------------------------------------------------------------------
  // Edge counter and idle-level check
  //---------------------------------------------------------------------------
  // Written only here; the stimulus reads differences.
  int unsigned edges;
  int unsigned idle_errors;
  logic        sclk_q;
  logic        cpol_q;

  always @(posedge clk) begin
    if (!rst_n) begin
      edges       = 0;
      idle_errors = 0;
      sclk_q      = sclk;
      cpol_q      = cpol;
    end else begin
      if (!cs_n && sclk != sclk_q) edges++;
      // SCLK follows a change of cpol one cycle later.
      if (cs_n && !busy && cpol == cpol_q && sclk != cpol) begin
        idle_errors++;
        $display("ERROR: SCLK %b not at cpol %b while deselected", sclk, cpol);
      end
      sclk_q = sclk;
      cpol_q = cpol;
    end
  end

  task automatic check(input logic ok, input string label);
    check_count++;
    if (!ok) begin
      error_count++;
      $display("ERROR: %s", label);
    end
  endtask

  // Inputs change on the falling edge, so they never race the design.
  task automatic send(input logic [DATA_WIDTH-1:0] d, input logic last);
    @(negedge clk);
    s_data  = d;
    s_last  = last;
    s_valid = 1'b1;
    while (!s_ready) @(negedge clk);
    @(posedge clk);
    #1 s_valid = 1'b0;
  endtask

  task automatic wait_word(output logic [DATA_WIDTH-1:0] d);
    do @(posedge clk); while (!m_valid);
    d = m_data;
  endtask

  task automatic wait_idle();
    while (busy) @(posedge clk);
    @(posedge clk);
  endtask

  initial begin
    logic [DATA_WIDTH-1:0] got;
    int unsigned           start_edges;

    error_count = 0;
    check_count = 0;
    cpol = 1'b0; cpha = 1'b0; lsb_first = 1'b0; clk_div = DIV_WIDTH'(2);
    s_valid = 1'b0; s_data = '0; s_last = 1'b0;
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    check(cs_n === 1'b1 && sclk === 1'b0 && s_ready === 1'b1, "reset state");

    for (int mode = 0; mode < 8; mode++) begin
      @(negedge clk);
      cpol      = mode[0];
      cpha      = mode[1];
      lsb_first = mode[2];
      clk_div   = DIV_WIDTH'(1 + (mode % 3));
      repeat (3) @(posedge clk);

      // A three-word frame, checked word by word and by edge count.
      start_edges = edges;
      for (int w = 0; w < 3; w++) begin
        automatic logic [DATA_WIDTH-1:0] word = DATA_WIDTH'($urandom());
        send(word, w == 2);
        wait_word(got);
        check(got == word, $sformatf("mode %0d word %0d: sent %h got %h",
                                     mode, w, word, got));
      end
      wait_idle();
      check(edges - start_edges == 3 * 2 * DATA_WIDTH,
            $sformatf("mode %0d: %0d SCLK edges for 3 words", mode,
                      edges - start_edges));
      check(cs_n === 1'b1 && sclk === cpol, $sformatf("mode %0d idle", mode));
    end

    error_count += idle_errors;
    if (error_count == 0) begin
      $display("TEST PASSED: tb_spi_master (%0d checks, DATA_WIDTH=%0d)",
               check_count, DATA_WIDTH);
      $finish;
    end else begin
      $display("TEST FAILED: tb_spi_master, %0d error(s) in %0d checks",
               error_count, check_count);
      $fatal(1, "tb_spi_master failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 500000);
    $fatal(1, "tb_spi_master: global timeout");
  end

endmodule

`default_nettype wire
