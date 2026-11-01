//=============================================================================
// Testbench   : tb_i2c_master
// Description : Self-checking SystemVerilog testbench for i2c_master.
//
// The Python-free smoke test. A behavioural EEPROM-style slave at address
// 0x50 (register pointer, auto-increment) sits on an open-drain bus with the
// master. The testbench writes a block of registers, reads it back through a
// repeated START, and checks that an unowned address is NACKed, at two SCL
// rates. The full suites, including clock stretching and arbitration, live in
// cocotb/test_i2c_master.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_i2c_master;

  localparam int unsigned DIV_WIDTH  = 8;
  localparam time         CLK_PERIOD = 10ns;
  localparam logic [6:0]  SLAVE_ADDR = 7'h50;

  localparam logic [1:0] CMD_START = 2'd0, CMD_STOP = 2'd1,
                         CMD_WRITE = 2'd2, CMD_READ = 2'd3;

  logic                 clk;
  logic                 rst_n;
  logic [DIV_WIDTH-1:0] clk_div;
  logic                 s_valid;
  logic                 s_ready;
  logic [1:0]           s_cmd;
  logic [7:0]           s_data;
  logic                 s_nack;
  logic                 m_valid;
  logic [7:0]           m_data;
  logic                 m_nack;
  logic                 m_arb_lost;
  logic                 busy;
  logic                 scl_oe;
  logic                 sda_oe;

  // Open-drain bus
  logic slave_sda_low;
  logic scl;
  logic sda;
  assign scl = !scl_oe;
  assign sda = !(sda_oe || slave_sda_low);

  int unsigned error_count;
  int unsigned check_count;

  i2c_master #(
      .DIV_WIDTH (DIV_WIDTH)
  ) dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .clk_div    (clk_div),
      .s_valid    (s_valid),
      .s_ready    (s_ready),
      .s_cmd      (s_cmd),
      .s_data     (s_data),
      .s_nack     (s_nack),
      .m_valid    (m_valid),
      .m_data     (m_data),
      .m_nack     (m_nack),
      .m_arb_lost (m_arb_lost),
      .busy       (busy),
      .scl_i      (scl),
      .sda_i      (sda),
      .scl_oe     (scl_oe),
      .sda_oe     (sda_oe)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Behavioural slave, sampled on the system clock
  //---------------------------------------------------------------------------
  typedef enum int {SL_IDLE, SL_RX, SL_ACK_OUT, SL_TX, SL_ACK_IN} sl_state_t;

  sl_state_t  sl_state;
  logic [7:0] memory [256];
  logic [7:0] sl_shift;
  logic [7:0] sl_tx;
  logic [7:0] pointer;
  int         sl_bits;
  logic       first_byte;
  logic       addressed;
  logic       reading;
  logic       pointer_set;
  logic       master_nack;
  logic       scl_q;
  logic       sda_q;

  always @(posedge clk) begin
    if (!rst_n) begin
      sl_state      = SL_IDLE;
      slave_sda_low = 1'b0;
      scl_q         = 1'b1;
      sda_q         = 1'b1;
    end else begin
      if (scl_q && scl && sda != sda_q) begin
        // START (SDA falls) or STOP (SDA rises) while SCL is high
        slave_sda_low = 1'b0;
        if (!sda) begin
          sl_state   = SL_RX;
          sl_bits    = 0;
          first_byte = 1'b1;
        end else begin
          sl_state = SL_IDLE;
        end
      end else if (!scl_q && scl) begin
        // SCL rising: sample
        if (sl_state == SL_RX) begin
          sl_shift = {sl_shift[6:0], sda};
          sl_bits++;
        end else if (sl_state == SL_TX) begin
          sl_bits++;
        end else if (sl_state == SL_ACK_IN) begin
          master_nack = sda;
        end
      end else if (scl_q && !scl) begin
        // SCL falling: drive
        case (sl_state)
          SL_RX: if (sl_bits == 8) begin
            if (first_byte) begin
              addressed = (sl_shift[7:1] == SLAVE_ADDR);
              reading   = sl_shift[0];
            end
            slave_sda_low = first_byte ? addressed : 1'b1;
            sl_state      = SL_ACK_OUT;
          end
          SL_ACK_OUT: begin
            slave_sda_low = 1'b0;
            if (first_byte) begin
              first_byte  = 1'b0;
              pointer_set = 1'b0;
              if (!addressed) begin
                sl_state = SL_IDLE;
              end else if (reading) begin
                sl_tx         = memory[pointer];
                pointer       = pointer + 8'd1;
                sl_bits       = 0;
                slave_sda_low = !sl_tx[7];
                sl_state      = SL_TX;
              end else begin
                sl_bits  = 0;
                sl_state = SL_RX;
              end
            end else begin
              if (!pointer_set) begin
                pointer     = sl_shift;
                pointer_set = 1'b1;
              end else begin
                memory[pointer] = sl_shift;
                pointer         = pointer + 8'd1;
              end
              sl_bits  = 0;
              sl_state = SL_RX;
            end
          end
          SL_TX: begin
            if (sl_bits == 8) begin
              slave_sda_low = 1'b0;
              sl_state      = SL_ACK_IN;
            end else begin
              slave_sda_low = !sl_tx[7 - sl_bits];
            end
          end
          SL_ACK_IN: begin
            if (master_nack) begin
              slave_sda_low = 1'b0;
              sl_state      = SL_IDLE;
            end else begin
              sl_tx         = memory[pointer];
              pointer       = pointer + 8'd1;
              sl_bits       = 0;
              slave_sda_low = !sl_tx[7];
              sl_state      = SL_TX;
            end
          end
          default: ;
        endcase
      end
      scl_q = scl;
      sda_q = sda;
    end
  end

  //---------------------------------------------------------------------------
  // Host
  //---------------------------------------------------------------------------
  task automatic check(input logic ok, input string label);
    check_count++;
    if (!ok) begin
      error_count++;
      $display("ERROR: %s", label);
    end
  endtask

  // One command, one response. Inputs change on the falling edge.
  task automatic command(input logic [1:0] cmd, input logic [7:0] data,
                         input logic nack, output logic [7:0] rdata,
                         output logic rnack);
    @(negedge clk);
    s_cmd   = cmd;
    s_data  = data;
    s_nack  = nack;
    s_valid = 1'b1;
    while (!s_ready) @(negedge clk);
    @(posedge clk);
    #1 s_valid = 1'b0;
    do @(posedge clk); while (!m_valid);
    rdata = m_data;
    rnack = m_nack;
    check(!m_arb_lost, "no arbitration loss on a single-master bus");
  endtask

  initial begin
    logic [7:0] rd;
    logic       nk;
    logic [7:0] block [6] = '{8'h00, 8'hFF, 8'h96, 8'h69, 8'h01, 8'h80};

    error_count = 0;
    check_count = 0;
    clk_div = DIV_WIDTH'(2);
    s_valid = 1'b0; s_cmd = '0; s_data = '0; s_nack = 1'b0;
    for (int i = 0; i < 256; i++) memory[i] = 8'h00;
    pointer = '0;
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    check(!scl_oe && !sda_oe && s_ready, "reset state");

    for (int pass = 0; pass < 2; pass++) begin
      automatic logic [7:0] base = 8'h20 + 8'(pass * 16);
      clk_div = DIV_WIDTH'(pass == 0 ? 2 : 5);

      // Register write
      command(CMD_START, '0, 1'b0, rd, nk);
      command(CMD_WRITE, {SLAVE_ADDR, 1'b0}, 1'b0, rd, nk);
      check(!nk, "address+W acknowledged");
      command(CMD_WRITE, base, 1'b0, rd, nk);
      check(!nk, "register acknowledged");
      foreach (block[i]) begin
        command(CMD_WRITE, block[i] ^ 8'(pass), 1'b0, rd, nk);
        check(!nk, $sformatf("data %0d acknowledged", i));
      end
      command(CMD_STOP, '0, 1'b0, rd, nk);
      foreach (block[i]) begin
        check(memory[base + 8'(i)] == (block[i] ^ 8'(pass)),
              $sformatf("slave register %h", base + 8'(i)));
      end

      // Register read with a repeated START
      command(CMD_START, '0, 1'b0, rd, nk);
      command(CMD_WRITE, {SLAVE_ADDR, 1'b0}, 1'b0, rd, nk);
      command(CMD_WRITE, base, 1'b0, rd, nk);
      command(CMD_START, '0, 1'b0, rd, nk);
      command(CMD_WRITE, {SLAVE_ADDR, 1'b1}, 1'b0, rd, nk);
      check(!nk, "address+R acknowledged");
      foreach (block[i]) begin
        command(CMD_READ, '0, (i == 5), rd, nk);
        check(rd == (block[i] ^ 8'(pass)),
              $sformatf("read %0d: got %h expected %h", i, rd,
                        block[i] ^ 8'(pass)));
      end
      command(CMD_STOP, '0, 1'b0, rd, nk);

      // Nobody at this address
      command(CMD_START, '0, 1'b0, rd, nk);
      command(CMD_WRITE, {7'h11, 1'b0}, 1'b0, rd, nk);
      check(nk, "unowned address NACKed");
      command(CMD_STOP, '0, 1'b0, rd, nk);
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_i2c_master (%0d checks)", check_count);
      $finish;
    end else begin
      $display("TEST FAILED: tb_i2c_master, %0d error(s) in %0d checks",
               error_count, check_count);
      $fatal(1, "tb_i2c_master failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 2000000);
    $fatal(1, "tb_i2c_master: global timeout");
  end

endmodule

`default_nettype wire
