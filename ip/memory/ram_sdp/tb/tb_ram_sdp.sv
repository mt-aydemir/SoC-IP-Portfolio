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

  // A second instance, with byte enables and preloaded through INIT_FILE.
  // run_svtb.py defines SOC_IP_TB_DIR as this file's directory, which is
  // where ram_init.hex lives.
  localparam int unsigned         INIT_WORDS = 8;
  localparam logic [DATA_WIDTH-1:0] INIT_DATA [INIT_WORDS] = '{
      32'h0011_2233, 32'h4455_6677, 32'h8899_AABB, 32'hCCDD_EEFF,
      32'h0F1E_2D3C, 32'h4B5A_6978, 32'h8796_A5B4, 32'hC3D2_E1F0};
  logic                  alt_wr_en, alt_rd_en;
  logic [3:0]            alt_wr_be;
  logic [ADDR_WIDTH-1:0] alt_wr_addr, alt_rd_addr;
  logic [DATA_WIDTH-1:0] alt_wr_data, alt_rd_data;

  ram_sdp #(
      .DATA_WIDTH  (DATA_WIDTH),
      .DEPTH       (DEPTH),
      .BYTE_ENABLE (1),
      .OUTPUT_REG  (0),
      .INIT_FILE   ({`SOC_IP_TB_DIR, "/ram_init.hex"})
  ) dut_alt (
      .wr_clk  (wr_clk),
      .wr_en   (alt_wr_en),
      .wr_be   (alt_wr_be),
      .wr_addr (alt_wr_addr),
      .wr_data (alt_wr_data),
      .rd_clk  (rd_clk),
      .rd_en   (alt_rd_en),
      .rd_addr (alt_rd_addr),
      .rd_data (alt_rd_data)
  );

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

  task automatic alt_write(input logic [ADDR_WIDTH-1:0] a,
                           input logic [DATA_WIDTH-1:0] d,
                           input logic [3:0]            mask);
    @(negedge wr_clk);
    alt_wr_en   = 1'b1;
    alt_wr_be   = mask;
    alt_wr_addr = a;
    alt_wr_data = d;
    @(posedge wr_clk);
    @(negedge wr_clk);
    alt_wr_en = 1'b0;
  endtask

  task automatic alt_read_check(input logic [ADDR_WIDTH-1:0] a,
                                input logic [DATA_WIDTH-1:0] expect_rdata,
                                input string                 context_name);
    @(negedge rd_clk);
    alt_rd_en   = 1'b1;
    alt_rd_addr = a;
    @(posedge rd_clk);
    @(negedge rd_clk);
    alt_rd_en = 1'b0;
    #1;
    if (alt_rd_data !== expect_rdata) begin
      error_count++;
      $error("%s: address %0d expected 0x%0h, got 0x%0h", context_name, a,
             expect_rdata, alt_rd_data);
    end
  endtask

  task automatic alt_checks();
    for (int unsigned i = 0; i < INIT_WORDS; i++) begin
      alt_read_check(ADDR_WIDTH'(i), INIT_DATA[i], "INIT_FILE contents");
    end
    // Byte enables: each lane written alone leaves the others as loaded.
    alt_write(ADDR_WIDTH'(2), 32'hFFFF_FFFF, 4'b0100);
    alt_read_check(ADDR_WIDTH'(2), 32'h88FF_AABB, "one byte lane");
    alt_write(ADDR_WIDTH'(2), 32'h0000_0000, 4'b1001);
    alt_read_check(ADDR_WIDTH'(2), 32'h00FF_AA00, "two byte lanes");
    alt_write(ADDR_WIDTH'(2), 32'h1234_5678, 4'b0000);
    alt_read_check(ADDR_WIDTH'(2), 32'h00FF_AA00, "no lane enabled");
  endtask

  initial begin
    error_count = 0;
    alt_wr_en   = 1'b0;
    alt_rd_en   = 1'b0;
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

    // --- the second instance: byte enables, INIT_FILE ---------------------------
    alt_checks();

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
