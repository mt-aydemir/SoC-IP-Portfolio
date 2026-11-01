//=============================================================================
// Testbench   : tb_gpio
// Description : Self-checking SystemVerilog testbench for gpio.
//
// The Python-free smoke test. A cycle-accurate reference model with its own
// synchroniser pipeline runs beside the design; every output is compared
// after every edge, through directed register accesses and then randomised
// writes with toggling pins. The full suites live in cocotb/test_gpio.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_gpio;

  localparam int unsigned WIDTH       = 8;
  localparam int unsigned SYNC_STAGES = 2;
  localparam time         CLK_PERIOD  = 10ns;
  localparam int unsigned NUM_RANDOM  = 4000;

  localparam logic [2:0] A_OUT = 3'd0, A_DIR = 3'd1, A_IN = 3'd2,
                         A_SET = 3'd3, A_CLR = 3'd4, A_RISE = 3'd5,
                         A_FALL = 3'd6, A_STATUS = 3'd7;

  logic             clk;
  logic             rst_n;
  logic [2:0]       addr;
  logic             wr_en;
  logic [WIDTH-1:0] wr_data;
  logic [WIDTH-1:0] rd_data;
  logic [WIDTH-1:0] pin_in;
  logic [WIDTH-1:0] pin_out;
  logic [WIDTH-1:0] pin_oe;
  logic             irq;

  // Reference state
  logic [WIDTH-1:0] m_sync [SYNC_STAGES];
  logic [WIDTH-1:0] m_prev, m_out, m_dir, m_rise, m_fall, m_status;

  int unsigned error_count;
  int unsigned check_count;

  gpio #(
      .WIDTH       (WIDTH),
      .SYNC_STAGES (SYNC_STAGES)
  ) dut (
      .clk     (clk),
      .rst_n   (rst_n),
      .addr    (addr),
      .wr_en   (wr_en),
      .wr_data (wr_data),
      .rd_data (rd_data),
      .pin_in  (pin_in),
      .pin_out (pin_out),
      .pin_oe  (pin_oe),
      .irq     (irq)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Reference model, written from the register map
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < SYNC_STAGES; s++) m_sync[s] <= '0;
      m_prev   <= '0;
      m_out    <= '0;
      m_dir    <= '0;
      m_rise   <= '0;
      m_fall   <= '0;
      m_status <= '0;
    end else begin
      automatic logic [WIDTH-1:0] cur = m_sync[SYNC_STAGES-1];
      automatic logic [WIDTH-1:0] clr = (wr_en && addr == A_STATUS) ? wr_data : '0;

      m_status <= (m_status & ~clr) | (cur & ~m_prev & m_rise)
                | (~cur & m_prev & m_fall);
      m_prev   <= cur;
      m_sync[0] <= pin_in;
      for (int s = 1; s < SYNC_STAGES; s++) m_sync[s] <= m_sync[s-1];

      if (wr_en) begin
        case (addr)
          A_OUT:  m_out  <= wr_data;
          A_DIR:  m_dir  <= wr_data;
          A_SET:  m_out  <= m_out | wr_data;
          A_CLR:  m_out  <= m_out & ~wr_data;
          A_RISE: m_rise <= wr_data;
          A_FALL: m_fall <= wr_data;
          default: ;
        endcase
      end
    end
  end

  function automatic logic [WIDTH-1:0] model_read(input logic [2:0] a);
    case (a)
      A_OUT:    return m_out;
      A_DIR:    return m_dir;
      A_IN:     return m_sync[SYNC_STAGES-1];
      A_RISE:   return m_rise;
      A_FALL:   return m_fall;
      A_STATUS: return m_status;
      default:  return '0;
    endcase
  endfunction

  task automatic compare(input string label);
    check_count++;
    if (rd_data !== model_read(addr) || pin_out !== m_out ||
        pin_oe !== m_dir || irq !== (m_status != '0)) begin
      error_count++;
      $display("ERROR %s: addr=%0d rd=%h/%h out=%h/%h oe=%h/%h irq=%b/%b",
               label, addr, rd_data, model_read(addr), pin_out, m_out,
               pin_oe, m_dir, irq, (m_status != '0));
    end
  endtask

  // One cycle: drive before the edge, compare after it.
  task automatic step(input logic [2:0] a, input logic we,
                      input logic [WIDTH-1:0] d, input logic [WIDTH-1:0] pins,
                      input string label);
    addr    = a;
    wr_en   = we;
    wr_data = d;
    pin_in  = pins;
    @(posedge clk);
    #1;
    compare(label);
  endtask

  initial begin
    error_count = 0;
    check_count = 0;
    addr = '0; wr_en = 1'b0; wr_data = '0; pin_in = '0;
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;

    // --- directed ----------------------------------------------------------
    step(A_OUT,  1'b1, 8'h3C, '0, "write OUT");
    step(A_DIR,  1'b1, 8'hF0, '0, "write DIR");
    step(A_SET,  1'b1, 8'h01, '0, "OUT_SET");
    step(A_CLR,  1'b1, 8'h0C, '0, "OUT_CLR");
    step(A_OUT,  1'b0, '0,    '0, "read OUT");
    step(A_RISE, 1'b1, 8'h0F, '0, "RISE_EN");
    step(A_FALL, 1'b1, 8'hF0, '0, "FALL_EN");
    for (int i = 0; i < 6; i++) step(A_STATUS, 1'b0, '0, 8'hFF, "all rise");
    for (int i = 0; i < 6; i++) step(A_STATUS, 1'b0, '0, 8'h00, "all fall");
    step(A_STATUS, 1'b1, 8'hFF, '0, "clear all");
    step(A_IN, 1'b0, '0, 8'hA5, "pins A5");
    for (int i = 0; i < 4; i++) step(A_IN, 1'b0, '0, 8'hA5, "IN settles");

    // --- randomised --------------------------------------------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      automatic logic [WIDTH-1:0] pins = pin_in;
      if ($urandom_range(0, 3) == 0) pins[$urandom_range(0, WIDTH-1)] ^= 1'b1;
      step(3'($urandom_range(0, 7)), ($urandom_range(0, 9) < 3),
           WIDTH'($urandom()), pins, "random");
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_gpio (%0d checks, WIDTH=%0d SYNC_STAGES=%0d)",
               check_count, WIDTH, SYNC_STAGES);
      $finish;
    end else begin
      $display("TEST FAILED: tb_gpio, %0d error(s) in %0d checks",
               error_count, check_count);
      $fatal(1, "tb_gpio failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 200000);
    $fatal(1, "tb_gpio: global timeout");
  end

endmodule

`default_nettype wire
