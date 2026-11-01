//=============================================================================
// Testbench   : tb_template_ip
// Description : Self-checking SystemVerilog testbench for template_ip.
//
// The Python-free smoke test. It runs on any SystemVerilog simulator, which
// makes it the fastest signal during development and the fallback when cocotb
// is not available. The exhaustive directed, randomised and regression suites
// live in cocotb/test_template_ip.py.
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

module tb_template_ip;

  localparam int unsigned DATA_WIDTH = 8;
  localparam time         CLK_PERIOD = 10ns;
  localparam int unsigned NUM_RANDOM = 500;

  logic                  clk;
  logic                  rst_n;
  logic                  s_valid;
  logic                  s_ready;
  logic [DATA_WIDTH-1:0] s_data;
  logic                  m_valid;
  logic                  m_ready;
  logic [DATA_WIDTH-1:0] m_data;

  int unsigned           error_count;
  int unsigned           sent_count;
  int unsigned           recv_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  template_ip #(
      .DATA_WIDTH (DATA_WIDTH)
  ) dut (
      .clk     (clk),
      .rst_n   (rst_n),
      .s_valid (s_valid),
      .s_ready (s_ready),
      .s_data  (s_data),
      .m_valid (m_valid),
      .m_ready (m_ready),
      .m_data  (m_data)
  );

  //---------------------------------------------------------------------------
  // Clock
  //---------------------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Reference model: an in-order queue of the words accepted at the input.
  //---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] expected [$];

  always_ff @(posedge clk) begin
    if (rst_n && s_valid && s_ready) begin
      expected.push_back(s_data);
    end
  end

  //---------------------------------------------------------------------------
  // Output monitor: every accepted output word must match the head of the
  // reference queue.
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n && m_valid && m_ready) begin
      if (expected.size() == 0) begin
        error_count++;
        $error("output 0x%0h at time %0t was never presented at the input",
               m_data, $time);
      end else begin
        automatic logic [DATA_WIDTH-1:0] want = expected.pop_front();
        recv_count++;
        if (m_data !== want) begin
          error_count++;
          $error("transfer %0d: expected 0x%0h, got 0x%0h at time %0t",
                 recv_count, want, m_data, $time);
        end
      end
    end
  end

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  task automatic send(input logic [DATA_WIDTH-1:0] value);
    @(negedge clk);
    s_valid = 1'b1;
    s_data  = value;
    // Hold the request until the sink accepts it, as the protocol requires.
    do begin
      @(posedge clk);
    end while (s_ready !== 1'b1);
    @(negedge clk);
    s_valid = 1'b0;
    sent_count++;
  endtask

  initial begin
    error_count = 0;
    sent_count  = 0;
    recv_count  = 0;
    rst_n       = 1'b0;
    s_valid     = 1'b0;
    s_data      = '0;
    m_ready     = 1'b1;

    // --- reset -------------------------------------------------------------
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    #1;
    if (m_valid !== 1'b0) begin
      error_count++;
      $error("reset: m_valid should be low after reset");
    end

    // --- directed: a single transfer ---------------------------------------
    send(DATA_WIDTH'('hA5));
    repeat (2) @(posedge clk);

    // --- directed: back to back transfers ----------------------------------
    for (int unsigned i = 0; i < 8; i++) begin
      send(DATA_WIDTH'(i));
    end
    repeat (2) @(posedge clk);

    // --- randomised traffic with back pressure ------------------------------
    fork
      // Sink randomly withdraws ready to exercise the stall path.
      begin
        for (int unsigned i = 0; i < NUM_RANDOM * 4; i++) begin
          @(negedge clk);
          m_ready = ($urandom_range(0, 3) != 0);
        end
        m_ready = 1'b1;
      end
      begin
        for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
          send(DATA_WIDTH'($urandom()));
        end
      end
    join_any
    disable fork;

    // --- drain --------------------------------------------------------------
    m_ready = 1'b1;
    repeat (16) @(posedge clk);

    if (expected.size() != 0) begin
      error_count++;
      $error("%0d word(s) accepted at the input never appeared at the output",
             expected.size());
    end

    // --- verdict ------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_template_ip (%0d transfers, DATA_WIDTH=%0d)",
               recv_count, DATA_WIDTH);
      $finish;
    end else begin
      $display("TEST FAILED: tb_template_ip, %0d error(s)", error_count);
      $fatal(1, "tb_template_ip failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(CLK_PERIOD * 100000);
    $fatal(1, "tb_template_ip: global timeout");
  end

endmodule

`default_nettype wire
