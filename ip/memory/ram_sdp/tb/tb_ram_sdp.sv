//=============================================================================
// Testbench   : tb_ram_sdp
// Description : Self-checking SystemVerilog testbench for ram_sdp.
//
// Runs the write and read ports on unrelated clocks, because that is the
// configuration the block exists to support and the one a single-clock test
// would never exercise.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_ram_sdp;

  localparam int unsigned DATA_WIDTH  = 32;
  localparam int unsigned DEPTH       = 256;
  localparam int unsigned ADDR_WIDTH  = $clog2(DEPTH);
  localparam time         WR_PERIOD   = 10ns;
  localparam time         RD_PERIOD   = 17ns;

  logic                  wr_clk;
  logic                  wr_en;
  logic [3:0]            wr_be;
  logic [ADDR_WIDTH-1:0] wr_addr;
  logic [DATA_WIDTH-1:0] wr_data;

  logic                  rd_clk;
  logic                  rd_en;
  logic [ADDR_WIDTH-1:0] rd_addr;
  logic [DATA_WIDTH-1:0] rd_data;

  int unsigned           error_count;
  logic [DATA_WIDTH-1:0] model [DEPTH];

  ram_sdp #(
      .DATA_WIDTH  (DATA_WIDTH),
      .DEPTH       (DEPTH),
      .BYTE_ENABLE (0),
      .OUTPUT_REG  (0)
  ) dut (
      .wr_clk  (wr_clk),
      .wr_en   (wr_en),
      .wr_be   (wr_be),
      .wr_addr (wr_addr),
      .wr_data (wr_data),
      .rd_clk  (rd_clk),
      .rd_en   (rd_en),
      .rd_addr (rd_addr),
      .rd_data (rd_data)
  );

  initial begin
    wr_clk = 1'b0;
    forever #(WR_PERIOD / 2) wr_clk = ~wr_clk;
  end

  initial begin
    rd_clk = 1'b0;
    #3ns;
    forever #(RD_PERIOD / 2) rd_clk = ~rd_clk;
  end

  task automatic mem_write(input logic [ADDR_WIDTH-1:0] a,
                           input logic [DATA_WIDTH-1:0] d);
    @(negedge wr_clk);
    wr_en   = 1'b1;
    wr_addr = a;
    wr_data = d;
    @(posedge wr_clk);
    @(negedge wr_clk);
    wr_en    = 1'b0;
    model[a] = d;
  endtask

  task automatic mem_read_check(input logic [ADDR_WIDTH-1:0] a,
                                input string context_name);
    @(negedge rd_clk);
    rd_en   = 1'b1;
    rd_addr = a;
    @(posedge rd_clk);
    @(negedge rd_clk);
    rd_en = 1'b0;
    #1;
    if (rd_data !== model[a]) begin
      error_count++;
      $error("%s: address %0d expected 0x%0h, got 0x%0h at %0t",
             context_name, a, model[a], rd_data, $time);
    end
  endtask

  initial begin
    error_count = 0;
    wr_en       = 1'b0;
    wr_be       = '1;
    wr_addr     = '0;
    wr_data     = '0;
    rd_en       = 1'b0;
    rd_addr     = '0;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      model[i] = '0;
    end

    repeat (3) @(posedge wr_clk);

    // --- initialise so the model and the memory agree ------------------------
    for (int unsigned i = 0; i < DEPTH; i++) begin
      mem_write(ADDR_WIDTH'(i), '0);
    end

    // --- write then read across the clock boundary ---------------------------
    mem_write(ADDR_WIDTH'(0), 32'hDEAD_BEEF);
    mem_read_check(ADDR_WIDTH'(0), "first word");

    mem_write(ADDR_WIDTH'(DEPTH - 1), 32'hA5A5_5A5A);
    mem_read_check(ADDR_WIDTH'(DEPTH - 1), "last word");

    // --- same-address collision returns the old contents ---------------------
    mem_write(ADDR_WIDTH'(5), 32'h1111_1111);

    fork
      begin
        @(negedge wr_clk);
        wr_en   = 1'b1;
        wr_addr = ADDR_WIDTH'(5);
        wr_data = 32'h2222_2222;
        @(posedge wr_clk);
        @(negedge wr_clk);
        wr_en = 1'b0;
      end
      begin
        @(negedge rd_clk);
        rd_en   = 1'b1;
        rd_addr = ADDR_WIDTH'(5);
        @(posedge rd_clk);
        @(negedge rd_clk);
        rd_en = 1'b0;
      end
    join

    model[5] = 32'h2222_2222;
    mem_read_check(ADDR_WIDTH'(5), "after the collision the write must land");

    // --- every address is distinct --------------------------------------------
    for (int unsigned i = 0; i < DEPTH; i++) begin
      mem_write(ADDR_WIDTH'(i), DATA_WIDTH'(i * 32'h0101_0101 + 32'h9E37));
    end
    for (int unsigned i = 0; i < DEPTH; i++) begin
      mem_read_check(ADDR_WIDTH'(i), "full sweep");
    end

    // --- randomised traffic on both ports at once ------------------------------
    for (int unsigned i = 0; i < 200; i++) begin
      automatic logic [ADDR_WIDTH-1:0] a = ADDR_WIDTH'($urandom_range(0, DEPTH - 1));
      if ($urandom_range(0, 1) == 0) begin
        mem_write(a, DATA_WIDTH'($urandom()));
      end else begin
        mem_read_check(a, $sformatf("random %0d", i));
      end
    end

    // --- verdict ----------------------------------------------------------------
    repeat (2) @(posedge rd_clk);
    if (error_count == 0) begin
      $display("TEST PASSED: tb_ram_sdp (%0d x %0d, wr %0t / rd %0t)",
               DEPTH, DATA_WIDTH, WR_PERIOD, RD_PERIOD);
      $finish;
    end else begin
      $display("TEST FAILED: tb_ram_sdp, %0d error(s)", error_count);
      $fatal(1, "tb_ram_sdp failed");
    end
  end

  initial begin
    #(WR_PERIOD * 500000);
    $fatal(1, "tb_ram_sdp: global timeout");
  end

endmodule

`default_nettype wire
