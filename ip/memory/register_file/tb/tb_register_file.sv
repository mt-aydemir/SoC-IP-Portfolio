//=============================================================================
// Testbench   : tb_register_file
// Description : Self-checking SystemVerilog testbench for register_file.
//
// Checks the properties a processor datapath depends on: every register holds
// its own value, register zero reads as zero, and a read of the register being
// written returns the new data.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_register_file;

  localparam int unsigned DATA_WIDTH     = 32;
  localparam int unsigned NUM_REGS       = 32;
  localparam int unsigned NUM_READ_PORTS = 2;
  localparam int unsigned ADDR_WIDTH     = $clog2(NUM_REGS);
  localparam time         CLK_PERIOD     = 10ns;

  logic                                             clk;
  logic                                             rst_n;
  logic                                             write_en;
  logic [ADDR_WIDTH-1:0]                            write_addr;
  logic [DATA_WIDTH-1:0]                            write_data;
  logic [NUM_READ_PORTS-1:0][ADDR_WIDTH-1:0]        read_addr;
  logic [NUM_READ_PORTS-1:0][DATA_WIDTH-1:0]        read_data;

  int unsigned                                      error_count;
  logic [DATA_WIDTH-1:0]                            model [NUM_REGS];

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  register_file #(
      .DATA_WIDTH     (DATA_WIDTH),
      .NUM_REGS       (NUM_REGS),
      .NUM_READ_PORTS (NUM_READ_PORTS),
      .ZERO_REGISTER  (1),
      .BYPASS_WRITE   (1)
  ) dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .write_en   (write_en),
      .write_addr (write_addr),
      .write_data (write_data),
      .read_addr  (read_addr),
      .read_data  (read_data)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  task automatic check(input int unsigned port,
                       input logic [DATA_WIDTH-1:0] expected,
                       input string context_name);
    if (read_data[port] !== expected) begin
      error_count++;
      $error("%s: port %0d expected 0x%0h, got 0x%0h at %0t",
             context_name, port, expected, read_data[port], $time);
    end
  endtask

  task automatic do_write(input logic [ADDR_WIDTH-1:0] addr,
                          input logic [DATA_WIDTH-1:0] data);
    @(negedge clk);
    write_en   = 1'b1;
    write_addr = addr;
    write_data = data;
    @(posedge clk);
    @(negedge clk);
    write_en = 1'b0;
    if (addr != '0) begin
      model[addr] = data;
    end
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    write_en    = 1'b0;
    write_addr  = '0;
    write_data  = '0;
    read_addr   = '0;
    rst_n       = 1'b0;

    for (int unsigned r = 0; r < NUM_REGS; r++) begin
      model[r] = '0;
    end

    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);

    // --- reset clears everything --------------------------------------------
    for (int unsigned r = 0; r < NUM_REGS; r++) begin
      read_addr[0] = ADDR_WIDTH'(r);
      read_addr[1] = ADDR_WIDTH'(r);
      #1 check(0, '0, $sformatf("reset, register %0d", r));
    end

    // --- every register holds its own value ---------------------------------
    for (int unsigned r = 1; r < NUM_REGS; r++) begin
      do_write(ADDR_WIDTH'(r), DATA_WIDTH'(r * 32'h0101_0101 + 32'h1234));
    end

    for (int unsigned r = 0; r < NUM_REGS; r++) begin
      read_addr[0] = ADDR_WIDTH'(r);
      read_addr[1] = ADDR_WIDTH'((r + 1) % NUM_REGS);
      #1;
      check(0, model[r], $sformatf("sweep, port 0, register %0d", r));
      check(1, model[(r + 1) % NUM_REGS],
            $sformatf("sweep, port 1, register %0d", (r + 1) % NUM_REGS));
    end

    // --- register zero ignores writes and reads as zero ----------------------
    do_write('0, {DATA_WIDTH{1'b1}});
    read_addr[0] = '0;
    #1 check(0, '0, "register zero after a write to it");

    // --- read during write returns the new data ------------------------------
    @(negedge clk);
    write_en     = 1'b1;
    write_addr   = ADDR_WIDTH'(5);
    write_data   = 32'hFACE_B00C;
    read_addr[0] = ADDR_WIDTH'(5);
    read_addr[1] = ADDR_WIDTH'(6);
    #1;
    check(0, 32'hFACE_B00C, "read during write, same address");
    check(1, model[6], "read during write, different address");
    @(posedge clk);
    @(negedge clk);
    write_en  = 1'b0;
    model[5]  = 32'hFACE_B00C;

    read_addr[0] = ADDR_WIDTH'(5);
    #1 check(0, 32'hFACE_B00C, "the bypassed write must also have landed");

    // --- randomised traffic ---------------------------------------------------
    for (int unsigned i = 0; i < 500; i++) begin
      automatic logic [ADDR_WIDTH-1:0] waddr = ADDR_WIDTH'($urandom_range(0, NUM_REGS - 1));
      automatic logic [DATA_WIDTH-1:0] wdata = DATA_WIDTH'($urandom());
      automatic logic [ADDR_WIDTH-1:0] raddr = ADDR_WIDTH'($urandom_range(0, NUM_REGS - 1));

      @(negedge clk);
      write_en     = 1'b1;
      write_addr   = waddr;
      write_data   = wdata;
      read_addr[0] = raddr;
      #1;
      if (raddr == '0) begin
        check(0, '0, $sformatf("random %0d, register zero", i));
      end else if (raddr == waddr) begin
        check(0, wdata, $sformatf("random %0d, bypass", i));
      end else begin
        check(0, model[raddr], $sformatf("random %0d", i));
      end

      @(posedge clk);
      if (waddr != '0) begin
        model[waddr] = wdata;
      end
    end

    @(negedge clk);
    write_en = 1'b0;

    // --- verdict --------------------------------------------------------------
    repeat (2) @(posedge clk);
    if (error_count == 0) begin
      $display("TEST PASSED: tb_register_file (%0d registers, %0d read ports)",
               NUM_REGS, NUM_READ_PORTS);
      $finish;
    end else begin
      $display("TEST FAILED: tb_register_file, %0d error(s)", error_count);
      $fatal(1, "tb_register_file failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 200000);
    $fatal(1, "tb_register_file: global timeout");
  end

endmodule

`default_nettype wire
