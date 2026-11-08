//=============================================================================
// Testbench   : tb_ram_sp
// Description : Self-checking SystemVerilog testbench for ram_sp.
//
// Covers the four behaviours an integrator relies on: a word reads back as
// written, byte enables mask correctly, a coincident read returns the old
// contents, and every address is distinct.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_ram_sp;

  localparam int unsigned DATA_WIDTH = 32;
  localparam int unsigned DEPTH      = 256;
  localparam int unsigned ADDR_WIDTH = $clog2(DEPTH);
  localparam int unsigned NUM_BYTES  = DATA_WIDTH / 8;
  localparam time         CLK_PERIOD = 10ns;

  logic                    clk;
  logic                    en;
  logic                    we;
  logic [NUM_BYTES-1:0]    be;
  logic [ADDR_WIDTH-1:0]   addr;
  logic [DATA_WIDTH-1:0]   wdata;
  logic [DATA_WIDTH-1:0]   rdata;

  int unsigned             error_count;
  logic [DATA_WIDTH-1:0]   model [DEPTH];

  // A second instance, without byte enables and preloaded through INIT_FILE.
  // run_svtb.py defines SOC_IP_TB_DIR as this file's directory, which is
  // where ram_init.hex lives.
  localparam int unsigned         INIT_WORDS = 8;
  localparam logic [DATA_WIDTH-1:0] INIT_DATA [INIT_WORDS] = '{
      32'h0011_2233, 32'h4455_6677, 32'h8899_AABB, 32'hCCDD_EEFF,
      32'h0F1E_2D3C, 32'h4B5A_6978, 32'h8796_A5B4, 32'hC3D2_E1F0};
  logic                    alt_en, alt_we;
  logic [NUM_BYTES-1:0]    alt_be;
  logic [ADDR_WIDTH-1:0]   alt_addr;
  logic [DATA_WIDTH-1:0]   alt_wdata, alt_rdata;

  ram_sp #(
      .DATA_WIDTH  (DATA_WIDTH),
      .DEPTH       (DEPTH),
      .BYTE_ENABLE (0),
      .OUTPUT_REG  (0),
      .INIT_FILE   ({`SOC_IP_TB_DIR, "/ram_init.hex"})
  ) dut_alt (
      .clk   (clk),
      .en    (alt_en),
      .we    (alt_we),
      .be    (alt_be),
      .addr  (alt_addr),
      .wdata (alt_wdata),
      .rdata (alt_rdata)
  );

  ram_sp #(
      .DATA_WIDTH  (DATA_WIDTH),
      .DEPTH       (DEPTH),
      .BYTE_ENABLE (1),
      .OUTPUT_REG  (0)
  ) dut (
      .clk   (clk),
      .en    (en),
      .we    (we),
      .be    (be),
      .addr  (addr),
      .wdata (wdata),
      .rdata (rdata)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  task automatic mem_write(input logic [ADDR_WIDTH-1:0] a,
                           input logic [DATA_WIDTH-1:0] d,
                           input logic [NUM_BYTES-1:0]  mask);
    @(negedge clk);
    en    = 1'b1;
    we    = 1'b1;
    be    = mask;
    addr  = a;
    wdata = d;
    @(posedge clk);
    @(negedge clk);
    en = 1'b0;
    we = 1'b0;
    for (int unsigned b = 0; b < NUM_BYTES; b++) begin
      if (mask[b]) begin
        model[a][b*8 +: 8] = d[b*8 +: 8];
      end
    end
  endtask

  task automatic mem_read_check(input logic [ADDR_WIDTH-1:0] a,
                                input string context_name);
    @(negedge clk);
    en   = 1'b1;
    we   = 1'b0;
    addr = a;
    @(posedge clk);
    @(negedge clk);
    en = 1'b0;
    #1;
    if (rdata !== model[a]) begin
      error_count++;
      $error("%s: address %0d expected 0x%0h, got 0x%0h at %0t",
             context_name, a, model[a], rdata, $time);
    end
  endtask

  task automatic alt_access(input logic                  write,
                            input logic [ADDR_WIDTH-1:0] a,
                            input logic [DATA_WIDTH-1:0] d,
                            input logic [DATA_WIDTH-1:0] expect_rdata,
                            input string                 context_name);
    @(negedge clk);
    alt_en    = 1'b1;
    alt_we    = write;
    alt_be    = 4'b0001;   // ignored without byte enables
    alt_addr  = a;
    alt_wdata = d;
    @(posedge clk);
    @(negedge clk);
    alt_en = 1'b0;
    alt_we = 1'b0;
    #1;
    if (!write && alt_rdata !== expect_rdata) begin
      error_count++;
      $error("%s: address %0d expected 0x%0h, got 0x%0h", context_name, a,
             expect_rdata, alt_rdata);
    end
  endtask

  task automatic alt_checks();
    for (int unsigned i = 0; i < INIT_WORDS; i++) begin
      alt_access(1'b0, ADDR_WIDTH'(i), '0, INIT_DATA[i], "INIT_FILE contents");
    end
    // Without byte enables a write replaces the whole word, whatever be says.
    alt_access(1'b1, ADDR_WIDTH'(3), 32'h1234_5678, '0, "");
    alt_access(1'b0, ADDR_WIDTH'(3), '0, 32'h1234_5678, "whole-word write");
    alt_access(1'b0, ADDR_WIDTH'(4), '0, INIT_DATA[4], "neighbour untouched");
  endtask

  initial begin
    error_count = 0;
    alt_en      = 1'b0;
    alt_we      = 1'b0;
    en          = 1'b0;
    we          = 1'b0;
    be          = '1;
    addr        = '0;
    wdata       = '0;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      model[i] = '0;
    end

    repeat (3) @(posedge clk);

    // --- initialise the array so the model and the memory agree -------------
    for (int unsigned i = 0; i < DEPTH; i++) begin
      mem_write(ADDR_WIDTH'(i), '0, '1);
    end

    // --- write then read back -----------------------------------------------
    mem_write(ADDR_WIDTH'(0), 32'hDEAD_BEEF, '1);
    mem_read_check(ADDR_WIDTH'(0), "first word");

    mem_write(ADDR_WIDTH'(DEPTH - 1), 32'hA5A5_5A5A, '1);
    mem_read_check(ADDR_WIDTH'(DEPTH - 1), "last word");

    // --- byte enables ---------------------------------------------------------
    mem_write(ADDR_WIDTH'(7), '0, '1);
    for (int unsigned b = 0; b < NUM_BYTES; b++) begin
      mem_write(ADDR_WIDTH'(7), {DATA_WIDTH{1'b1}}, NUM_BYTES'(1 << b));
      mem_read_check(ADDR_WIDTH'(7), $sformatf("byte lane %0d", b));
    end

    // --- read during write returns the old contents ---------------------------
    mem_write(ADDR_WIDTH'(9), 32'h1111_1111, '1);

    @(negedge clk);
    en    = 1'b1;
    we    = 1'b1;
    be    = '1;
    addr  = ADDR_WIDTH'(9);
    wdata = 32'h2222_2222;
    @(posedge clk);
    @(negedge clk);
    en = 1'b0;
    we = 1'b0;
    #1;
    if (rdata !== 32'h1111_1111) begin
      error_count++;
      $error("read during write: expected the old value 0x11111111, got 0x%0h",
             rdata);
    end
    model[9] = 32'h2222_2222;
    mem_read_check(ADDR_WIDTH'(9), "after the coincident write");

    // --- every address is distinct --------------------------------------------
    for (int unsigned i = 0; i < DEPTH; i++) begin
      mem_write(ADDR_WIDTH'(i), DATA_WIDTH'(i * 32'h0101_0101 + 32'h9E37), '1);
    end
    for (int unsigned i = 0; i < DEPTH; i++) begin
      mem_read_check(ADDR_WIDTH'(i), "full sweep");
    end

    // --- randomised traffic ----------------------------------------------------
    for (int unsigned i = 0; i < 400; i++) begin
      automatic logic [ADDR_WIDTH-1:0] a = ADDR_WIDTH'($urandom_range(0, DEPTH - 1));
      if ($urandom_range(0, 1) == 0) begin
        mem_write(a, DATA_WIDTH'($urandom()), NUM_BYTES'($urandom_range(1, (1 << NUM_BYTES) - 1)));
      end else begin
        mem_read_check(a, $sformatf("random %0d", i));
      end
    end

    // --- the second instance: no byte enables, INIT_FILE ----------------------
    alt_checks();

    // --- verdict ----------------------------------------------------------------
    repeat (2) @(posedge clk);
    if (error_count == 0) begin
      $display("TEST PASSED: tb_ram_sp (%0d x %0d)", DEPTH, DATA_WIDTH);
      $finish;
    end else begin
      $display("TEST FAILED: tb_ram_sp, %0d error(s)", error_count);
      $fatal(1, "tb_ram_sp failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 500000);
    $fatal(1, "tb_ram_sp: global timeout");
  end

endmodule

`default_nettype wire
