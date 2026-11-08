//=============================================================================
// Testbench   : tb_ram_dp
// Description : Self-checking SystemVerilog testbench for ram_dp.
//
// The two ports run on unrelated clocks and share a partitioned address space:
// port A owns the even addresses, port B the odd ones. That partitioning is
// not a limitation of the test but the documented way to use a memory that
// does not arbitrate - a same-address collision is undefined by construction,
// so there is nothing meaningful to check about it.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_ram_dp;

  localparam int unsigned DATA_WIDTH = 32;
  localparam int unsigned DEPTH      = 256;
  localparam int unsigned ADDR_WIDTH = $clog2(DEPTH);
  localparam time         A_PERIOD   = 10ns;
  localparam time         B_PERIOD   = 17ns;

  logic                  clk_a, en_a, we_a;
  logic [3:0]            be_a;
  logic [ADDR_WIDTH-1:0] addr_a;
  logic [DATA_WIDTH-1:0] wdata_a, rdata_a;

  logic                  clk_b, en_b, we_b;
  logic [3:0]            be_b;
  logic [ADDR_WIDTH-1:0] addr_b;
  logic [DATA_WIDTH-1:0] wdata_b, rdata_b;

  int unsigned           error_count;
  logic [DATA_WIDTH-1:0] model [DEPTH];

  // A second instance, without byte enables and preloaded through INIT_FILE.
  // run_svtb.py defines SOC_IP_TB_DIR as this file's directory, which is
  // where ram_init.hex lives.
  localparam int unsigned         INIT_WORDS = 8;
  localparam logic [DATA_WIDTH-1:0] INIT_DATA [INIT_WORDS] = '{
      32'h0011_2233, 32'h4455_6677, 32'h8899_AABB, 32'hCCDD_EEFF,
      32'h0F1E_2D3C, 32'h4B5A_6978, 32'h8796_A5B4, 32'hC3D2_E1F0};
  logic                  alt_en_a, alt_we_a, alt_en_b, alt_we_b;
  logic [ADDR_WIDTH-1:0] alt_addr_a, alt_addr_b;
  logic [DATA_WIDTH-1:0] alt_wdata_a, alt_rdata_a, alt_wdata_b, alt_rdata_b;

  ram_dp #(
      .DATA_WIDTH  (DATA_WIDTH),
      .DEPTH       (DEPTH),
      .BYTE_ENABLE (0),
      .OUTPUT_REG  (0),
      .INIT_FILE   ({`SOC_IP_TB_DIR, "/ram_init.hex"})
  ) dut_alt (
      .clk_a (clk_a), .en_a (alt_en_a), .we_a (alt_we_a), .be_a (4'b0001),
      .addr_a (alt_addr_a), .wdata_a (alt_wdata_a), .rdata_a (alt_rdata_a),
      .clk_b (clk_b), .en_b (alt_en_b), .we_b (alt_we_b), .be_b (4'b0001),
      .addr_b (alt_addr_b), .wdata_b (alt_wdata_b), .rdata_b (alt_rdata_b)
  );

  // The concurrent phase is driven by two independent processes rather than a
  // fork inside the main stimulus block: Verilator 5.020 miscompiles a fork
  // whose branches call automatic tasks containing timing controls, and the
  // resulting model aborts at run time. Two initial blocks with an explicit
  // start and done handshake express the same thing and compile correctly.
  logic concurrent_go;
  logic concurrent_done_a;
  logic concurrent_done_b;

  ram_dp #(
      .DATA_WIDTH  (DATA_WIDTH),
      .DEPTH       (DEPTH),
      .BYTE_ENABLE (1),
      .OUTPUT_REG  (0)
  ) dut (
      .clk_a (clk_a), .en_a (en_a), .we_a (we_a), .be_a (be_a),
      .addr_a (addr_a), .wdata_a (wdata_a), .rdata_a (rdata_a),
      .clk_b (clk_b), .en_b (en_b), .we_b (we_b), .be_b (be_b),
      .addr_b (addr_b), .wdata_b (wdata_b), .rdata_b (rdata_b)
  );

  initial begin
    clk_a = 1'b0;
    forever #(A_PERIOD / 2) clk_a = ~clk_a;
  end

  initial begin
    clk_b = 1'b0;
    #3ns;
    forever #(B_PERIOD / 2) clk_b = ~clk_b;
  end

  // Port A or B of the second instance; be is tied to one lane and ignored.
  task automatic alt_access(input logic                  port_b,
                            input logic                  write,
                            input logic [ADDR_WIDTH-1:0] a,
                            input logic [DATA_WIDTH-1:0] d,
                            input logic [DATA_WIDTH-1:0] expect_rdata,
                            input string                 context_name);
    logic [DATA_WIDTH-1:0] got;
    if (port_b) begin
      @(negedge clk_b);
      alt_en_b = 1'b1; alt_we_b = write; alt_addr_b = a; alt_wdata_b = d;
      @(posedge clk_b);
      @(negedge clk_b);
      alt_en_b = 1'b0; alt_we_b = 1'b0;
      #1;
      got = alt_rdata_b;
    end else begin
      @(negedge clk_a);
      alt_en_a = 1'b1; alt_we_a = write; alt_addr_a = a; alt_wdata_a = d;
      @(posedge clk_a);
      @(negedge clk_a);
      alt_en_a = 1'b0; alt_we_a = 1'b0;
      #1;
      got = alt_rdata_a;
    end
    if (!write && got !== expect_rdata) begin
      error_count++;
      $error("%s: port %s address %0d expected 0x%0h, got 0x%0h", context_name,
             port_b ? "B" : "A", a, expect_rdata, got);
    end
  endtask

  task automatic alt_checks();
    for (int unsigned i = 0; i < INIT_WORDS; i++) begin
      alt_access(i[0], 1'b0, ADDR_WIDTH'(i), '0, INIT_DATA[i], "INIT_FILE contents");
    end
    // Without byte enables a write replaces the whole word, from either port.
    alt_access(1'b0, 1'b1, ADDR_WIDTH'(5), 32'hAAAA_5555, '0, "");
    alt_access(1'b1, 1'b0, ADDR_WIDTH'(5), '0, 32'hAAAA_5555, "A writes, B reads");
    alt_access(1'b1, 1'b1, ADDR_WIDTH'(6), 32'h5555_AAAA, '0, "");
    alt_access(1'b0, 1'b0, ADDR_WIDTH'(6), '0, 32'h5555_AAAA, "B writes, A reads");
  endtask

  task automatic write_a(input logic [ADDR_WIDTH-1:0] a,
                         input logic [DATA_WIDTH-1:0] d);
    @(negedge clk_a);
    en_a = 1'b1; we_a = 1'b1; be_a = '1; addr_a = a; wdata_a = d;
    @(posedge clk_a);
    @(negedge clk_a);
    en_a = 1'b0; we_a = 1'b0;
    model[a] = d;
  endtask

  task automatic write_b(input logic [ADDR_WIDTH-1:0] a,
                         input logic [DATA_WIDTH-1:0] d);
    @(negedge clk_b);
    en_b = 1'b1; we_b = 1'b1; be_b = '1; addr_b = a; wdata_b = d;
    @(posedge clk_b);
    @(negedge clk_b);
    en_b = 1'b0; we_b = 1'b0;
    model[a] = d;
  endtask

  task automatic read_check_a(input logic [ADDR_WIDTH-1:0] a,
                              input string context_name);
    @(negedge clk_a);
    en_a = 1'b1; we_a = 1'b0; addr_a = a;
    @(posedge clk_a);
    @(negedge clk_a);
    en_a = 1'b0;
    #1;
    if (rdata_a !== model[a]) begin
      error_count++;
      $error("%s: port A address %0d expected 0x%0h, got 0x%0h at %0t",
             context_name, a, model[a], rdata_a, $time);
    end
  endtask

  task automatic read_check_b(input logic [ADDR_WIDTH-1:0] a,
                              input string context_name);
    @(negedge clk_b);
    en_b = 1'b1; we_b = 1'b0; addr_b = a;
    @(posedge clk_b);
    @(negedge clk_b);
    en_b = 1'b0;
    #1;
    if (rdata_b !== model[a]) begin
      error_count++;
      $error("%s: port B address %0d expected 0x%0h, got 0x%0h at %0t",
             context_name, a, model[a], rdata_b, $time);
    end
  endtask

  initial begin
    error_count   = 0;
    alt_en_a = 1'b0; alt_we_a = 1'b0; alt_en_b = 1'b0; alt_we_b = 1'b0;
    concurrent_go = 1'b0;
    en_a = 1'b0; we_a = 1'b0; be_a = '1; addr_a = '0; wdata_a = '0;
    en_b = 1'b0; we_b = 1'b0; be_b = '1; addr_b = '0; wdata_b = '0;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      model[i] = '0;
    end

    repeat (3) @(posedge clk_a);

    for (int unsigned i = 0; i < DEPTH; i++) begin
      write_a(ADDR_WIDTH'(i), '0);
    end

    // --- each port reads its own writes --------------------------------------
    write_a(ADDR_WIDTH'(0), 32'hDEAD_BEEF);
    read_check_a(ADDR_WIDTH'(0), "port A own write");

    write_b(ADDR_WIDTH'(1), 32'hCAFE_BABE);
    read_check_b(ADDR_WIDTH'(1), "port B own write");

    // --- the ports share one array --------------------------------------------
    read_check_b(ADDR_WIDTH'(0), "port B sees port A write");
    read_check_a(ADDR_WIDTH'(1), "port A sees port B write");

    // --- concurrent traffic over a partitioned address space -------------------
    concurrent_go = 1'b1;
    wait (concurrent_done_a && concurrent_done_b);
    concurrent_go = 1'b0;

    // --- full sweep from A, read back from B ------------------------------------
    for (int unsigned i = 0; i < DEPTH; i++) begin
      write_a(ADDR_WIDTH'(i), DATA_WIDTH'(i * 32'h0101_0101 + 32'h9E37));
    end
    for (int unsigned i = 0; i < DEPTH; i++) begin
      read_check_b(ADDR_WIDTH'(i), "full sweep read from B");
    end

    // --- the second instance: no byte enables, INIT_FILE --------------------------
    alt_checks();

    // --- verdict ------------------------------------------------------------------
    repeat (2) @(posedge clk_a);
    if (error_count == 0) begin
      $display("TEST PASSED: tb_ram_dp (%0d x %0d, A %0t / B %0t)",
               DEPTH, DATA_WIDTH, A_PERIOD, B_PERIOD);
      $finish;
    end else begin
      $display("TEST FAILED: tb_ram_dp, %0d error(s)", error_count);
      $fatal(1, "tb_ram_dp failed");
    end
  end

  //---------------------------------------------------------------------------
  // Concurrent phase: port A works the even addresses while port B works the
  // odd ones, so the two never collide.
  //---------------------------------------------------------------------------
  initial begin : port_a_concurrent
    concurrent_done_a = 1'b0;
    wait (concurrent_go);
    for (int unsigned i = 0; i < 60; i++) begin
      write_a(ADDR_WIDTH'((i * 2) % DEPTH), DATA_WIDTH'(32'hA000_0000 + i));
      read_check_a(ADDR_WIDTH'((i * 2) % DEPTH),
                   $sformatf("port A concurrent %0d", i));
    end
    concurrent_done_a = 1'b1;
  end

  initial begin : port_b_concurrent
    concurrent_done_b = 1'b0;
    wait (concurrent_go);
    for (int unsigned i = 0; i < 60; i++) begin
      write_b(ADDR_WIDTH'((i * 2 + 1) % DEPTH),
              DATA_WIDTH'(32'hB000_0000 + i));
      read_check_b(ADDR_WIDTH'((i * 2 + 1) % DEPTH),
                   $sformatf("port B concurrent %0d", i));
    end
    concurrent_done_b = 1'b1;
  end

  initial begin
    #(A_PERIOD * 500000);
    $fatal(1, "tb_ram_dp: global timeout");
  end

endmodule

`default_nettype wire
