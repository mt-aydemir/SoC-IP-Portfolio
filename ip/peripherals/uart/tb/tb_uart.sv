//=============================================================================
// Testbench   : tb_uart
// Description : Self-checking SystemVerilog testbench for uart.
//
// The Python-free smoke test, built at a different geometry from the cocotb
// suite (7 data bits, odd parity, two stop bits) so the parameter space is
// covered at two points. It checks one transmitted frame bit by bit at its
// bit centres, injects a parity error and a framing error into the receiver
// directly, and then runs random words through a txd-to-rxd loopback at
// several bit periods. The full suites live in cocotb/test_uart.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_uart;

  localparam int unsigned DATA_BITS   = 7;
  localparam int unsigned PARITY      = 2;   // odd
  localparam int unsigned STOP_BITS   = 2;
  localparam int unsigned DIV_WIDTH   = 12;
  localparam time         CLK_PERIOD  = 10ns;
  localparam int unsigned FRAME_BITS  = 1 + DATA_BITS + 1 + STOP_BITS;

  logic                 clk;
  logic                 rst_n;
  logic [DIV_WIDTH-1:0] clks_per_bit;
  logic                 s_valid;
  logic                 s_ready;
  logic [DATA_BITS-1:0] s_data;
  logic                 txd;
  logic                 m_valid;
  logic                 m_ready;
  logic [DATA_BITS-1:0] m_data;
  logic                 m_parity_err;
  logic                 m_frame_err;
  logic                 rx_overrun;
  logic                 rxd;

  logic                 loopback;
  logic                 manual_rxd;

  int unsigned error_count;
  int unsigned check_count;

  assign rxd = loopback ? txd : manual_rxd;

  uart #(
      .DATA_BITS (DATA_BITS),
      .PARITY    (PARITY),
      .STOP_BITS (STOP_BITS),
      .DIV_WIDTH (DIV_WIDTH)
  ) dut (
      .clk          (clk),
      .rst_n        (rst_n),
      .clks_per_bit (clks_per_bit),
      .s_valid      (s_valid),
      .s_ready      (s_ready),
      .s_data       (s_data),
      .txd          (txd),
      .m_valid      (m_valid),
      .m_ready      (m_ready),
      .m_data       (m_data),
      .m_parity_err (m_parity_err),
      .m_frame_err  (m_frame_err),
      .rx_overrun   (rx_overrun),
      .rxd          (rxd)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  function automatic logic odd_parity(input logic [DATA_BITS-1:0] d);
    return ~(^d);
  endfunction

  task automatic check(input logic ok, input string label);
    check_count++;
    if (!ok) begin
      error_count++;
      $display("ERROR: %s", label);
    end
  endtask

  // Inputs change on the falling edge and s_ready is sampled there, where
  // it is stable. Raising s_valid in the same time step as a rising edge
  // races the design's always_ff: the word may be accepted on that very edge
  // while the task still sees s_ready high from before it, and is then sent
  // twice.
  task automatic send(input logic [DATA_BITS-1:0] d);
    @(negedge clk);
    s_data  = d;
    s_valid = 1'b1;
    while (!s_ready) @(negedge clk);
    @(posedge clk);
    #1 s_valid = 1'b0;
  endtask

  // Every accepted character is recorded here, so the stimulus can stay
  // sequential. (Verilator 5.020 miscompiles fork/join_none inside tasks.)
  int unsigned          rx_count;
  logic [DATA_BITS-1:0] rx_last;
  logic                 rx_last_perr;
  logic                 rx_last_ferr;

  logic [DATA_BITS-1:0] rx_log [$];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_count     = 0;
      rx_last      = '0;
      rx_last_perr = 1'b0;
      rx_last_ferr = 1'b0;
    end else if (m_valid && m_ready) begin
      rx_count     = rx_count + 1;
      rx_last      = m_data;
      rx_last_perr = m_parity_err;
      rx_last_ferr = m_frame_err;
      if (!m_parity_err && !m_frame_err) rx_log.push_back(m_data);
    end
  end

  // Wait until the receiver has delivered character number `count`.
  task automatic wait_rx(input int unsigned count, output logic got);
    got = 1'b0;
    for (int i = 0; i < 4 * FRAME_BITS * clks_per_bit; i++) begin
      if (rx_count >= count) begin
        got = 1'b1;
        break;
      end
      @(posedge clk);
    end
    #1;
  endtask

  task automatic drive_frame(input logic [DATA_BITS-1:0] d,
                             input logic flip_parity, input logic stop_level);
    logic [FRAME_BITS-1:0] bits;
    bits = '1;
    bits[0] = 1'b0;
    bits[DATA_BITS:1] = d;
    bits[DATA_BITS+1] = odd_parity(d) ^ flip_parity;
    bits[DATA_BITS+2] = stop_level;
    for (int b = 0; b < FRAME_BITS; b++) begin
      manual_rxd = bits[b];
      repeat (clks_per_bit) @(posedge clk);
    end
    manual_rxd = 1'b1;
    repeat (2 * clks_per_bit) @(posedge clk);
  endtask

  initial begin
    logic got;

    error_count  = 0;
    check_count  = 0;
    clks_per_bit = DIV_WIDTH'(10);
    s_valid      = 1'b0;
    s_data       = '0;
    m_ready      = 1'b1;
    loopback     = 1'b0;
    manual_rxd   = 1'b1;
    rst_n        = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    check(txd === 1'b1 && s_ready === 1'b1 && m_valid === 1'b0, "reset state");

    // --- one frame, sampled at the bit centres -----------------------------
    begin
      logic [DATA_BITS-1:0] w = 7'h4B;
      logic [FRAME_BITS-1:0] want;
      want = '1;
      want[0] = 1'b0;
      want[DATA_BITS:1] = w;
      want[DATA_BITS+1] = odd_parity(w);
      send(w);
      // txd changed on the accepting edge; the first centre is half a bit on.
      repeat (clks_per_bit / 2) @(posedge clk);
      for (int b = 0; b < FRAME_BITS; b++) begin
        check(txd === want[b], $sformatf("tx bit %0d of frame", b));
        repeat (clks_per_bit) @(posedge clk);
      end
    end

    // --- receiver errors ---------------------------------------------------
    drive_frame(7'h15, 1'b1, 1'b1);
    wait_rx(1, got);
    check(got && rx_last == 7'h15 && rx_last_perr && !rx_last_ferr,
          "parity error flagged");

    drive_frame(7'h2A, 1'b0, 1'b0);
    wait_rx(2, got);
    check(got && rx_last == 7'h2A && !rx_last_perr && rx_last_ferr,
          "framing error flagged");

    // --- loopback at several bit periods ----------------------------------
    loopback = 1'b1;
    foreach (clks_per_bit_list[k]) begin
      logic [DATA_BITS-1:0] sent [$];
      int unsigned          target;

      clks_per_bit = clks_per_bit_list[k];
      repeat (2 * FRAME_BITS * clks_per_bit) @(posedge clk);
      rx_log.delete();
      sent.delete();                  // block-scope queues are static
      target = rx_count + 40;
      for (int i = 0; i < 40; i++) begin
        sent.push_back(DATA_BITS'($urandom()));
        send(sent[i]);
      end
      wait_rx(target, got);
      check(got && rx_log.size() == 40,
            $sformatf("loopback cpb=%0d: %0d clean characters of 40",
                      clks_per_bit, rx_log.size()));
      for (int i = 0; i < 40 && i < rx_log.size(); i++) begin
        check(rx_log[i] == sent[i],
              $sformatf("loopback cpb=%0d word %0d: sent %h got %h",
                        clks_per_bit, i, sent[i], rx_log[i]));
      end
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_uart (%0d checks, DATA_BITS=%0d PARITY=%0d STOP_BITS=%0d)",
               check_count, DATA_BITS, PARITY, STOP_BITS);
      $finish;
    end else begin
      $display("TEST FAILED: tb_uart, %0d error(s) in %0d checks",
               error_count, check_count);
      $fatal(1, "tb_uart failed");
    end
  end

  logic [DIV_WIDTH-1:0] clks_per_bit_list [3] = '{DIV_WIDTH'(4), DIV_WIDTH'(7),
                                                  DIV_WIDTH'(23)};

  initial begin
    #(CLK_PERIOD * 2000000);
    $fatal(1, "tb_uart: global timeout");
  end

endmodule

`default_nettype wire
