//=============================================================================
// Testbench   : tb_axi4_lite_slave
// Description : Self-checking SystemVerilog testbench for axi4_lite_slave.
//
// The Python-free smoke test. The AW, W and AR channels are driven by three
// independent processes with their own random delays, so a write's data
// arrives before, with or after its address; B and R are back-pressured at
// random. Behind the bridge, a register block with pseudo-random wait states
// and one error word. Every register request is checked against the next
// expected write or read, and every B and R response against what that
// request was answered with. The full suite lives in
// cocotb/test_axi4_lite_slave.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_axi4_lite_slave;

  localparam int unsigned ADDR_WIDTH = 6;
  localparam int unsigned DATA_WIDTH = 32;
  localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8;
  localparam int unsigned WORDS      = 1 << (ADDR_WIDTH - 2);
  localparam int unsigned ERROR_WORD = WORDS - 1;
  localparam int unsigned NUM_OPS    = 3000;
  localparam time         CLK_PERIOD = 10ns;

  logic clk;
  logic rst_n;

  logic                  awvalid, awready, wvalid, wready, bvalid, bready;
  logic                  arvalid, arready, rvalid, rready;
  logic [ADDR_WIDTH-1:0] awaddr, araddr;
  logic [2:0]            awprot, arprot;
  logic [DATA_WIDTH-1:0] wdata, rdata;
  logic [STRB_WIDTH-1:0] wstrb;
  logic [1:0]            bresp, rresp;

  logic                  reg_valid, reg_ready, reg_write, reg_error;
  logic [ADDR_WIDTH-1:0] reg_addr;
  logic [DATA_WIDTH-1:0] reg_wdata, reg_rdata;
  logic [STRB_WIDTH-1:0] reg_strb;
  logic [2:0]            reg_prot;

  axi4_lite_slave #(
      .ADDR_WIDTH (ADDR_WIDTH),
      .DATA_WIDTH (DATA_WIDTH)
  ) dut (
      .clk           (clk),
      .rst_n         (rst_n),
      .s_axi_awvalid (awvalid),
      .s_axi_awready (awready),
      .s_axi_awaddr  (awaddr),
      .s_axi_awprot  (awprot),
      .s_axi_wvalid  (wvalid),
      .s_axi_wready  (wready),
      .s_axi_wdata   (wdata),
      .s_axi_wstrb   (wstrb),
      .s_axi_bvalid  (bvalid),
      .s_axi_bready  (bready),
      .s_axi_bresp   (bresp),
      .s_axi_arvalid (arvalid),
      .s_axi_arready (arready),
      .s_axi_araddr  (araddr),
      .s_axi_arprot  (arprot),
      .s_axi_rvalid  (rvalid),
      .s_axi_rready  (rready),
      .s_axi_rdata   (rdata),
      .s_axi_rresp   (rresp),
      .reg_valid     (reg_valid),
      .reg_ready     (reg_ready),
      .reg_write     (reg_write),
      .reg_addr      (reg_addr),
      .reg_wdata     (reg_wdata),
      .reg_strb      (reg_strb),
      .reg_prot      (reg_prot),
      .reg_rdata     (reg_rdata),
      .reg_error     (reg_error)
  );

  // The operations, split into the write and read sequences the channels
  // carry. Writes pair AW and W in order, as AXI4-Lite requires.
  logic [ADDR_WIDTH-1:0] w_addr [NUM_OPS];
  logic [DATA_WIDTH-1:0] w_data [NUM_OPS];
  logic [STRB_WIDTH-1:0] w_strb [NUM_OPS];
  logic [2:0]            w_prot [NUM_OPS];
  logic [ADDR_WIDTH-1:0] r_addr [NUM_OPS];
  logic [2:0]            r_prot [NUM_OPS];
  int unsigned           num_writes, num_reads;

  // Responses expected, posted when the register request is taken.
  logic [1:0]            exp_bresp [NUM_OPS];
  logic [DATA_WIDTH-1:0] exp_rdata [NUM_OPS];
  logic [1:0]            exp_rresp [NUM_OPS];

  logic [DATA_WIDTH-1:0] mem [WORDS];
  logic [15:0]           lfsr;
  int unsigned           wr_taken, rd_taken, b_seen, r_seen;
  logic                  ops_ready;

  int unsigned error_count;
  int unsigned check_count;

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Register block
  //---------------------------------------------------------------------------
  always_comb begin
    reg_ready = (lfsr[1:0] != 2'b00);
    reg_rdata = mem[reg_addr[ADDR_WIDTH-1:2]];
    reg_error = (reg_addr[ADDR_WIDTH-1:2] == ERROR_WORD[ADDR_WIDTH-3:0]);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      lfsr     <= 16'h1D0F;
      wr_taken <= 0;
      rd_taken <= 0;
      for (int w = 0; w < WORDS; w++) mem[w] <= '0;
    end else begin
      lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
      if (reg_valid && reg_ready) begin
        check_count++;
        if (reg_write) begin
          if (reg_addr !== w_addr[wr_taken] || reg_wdata !== w_data[wr_taken] ||
              reg_strb !== w_strb[wr_taken] || reg_prot !== w_prot[wr_taken]) begin
            error_count++;
            $display("ERROR: write %0d request %h/%h/%h/%h expected %h/%h/%h/%h",
                     wr_taken, reg_addr, reg_wdata, reg_strb, reg_prot,
                     w_addr[wr_taken], w_data[wr_taken], w_strb[wr_taken],
                     w_prot[wr_taken]);
          end
          exp_bresp[wr_taken] <= reg_error ? 2'b10 : 2'b00;
          wr_taken <= wr_taken + 1;
          if (!reg_error) begin
            for (int b = 0; b < STRB_WIDTH; b++) begin
              if (reg_strb[b]) mem[reg_addr[ADDR_WIDTH-1:2]][8*b +: 8] <= reg_wdata[8*b +: 8];
            end
          end
        end else begin
          if (reg_addr !== r_addr[rd_taken] || reg_prot !== r_prot[rd_taken] ||
              reg_strb !== '0 || reg_wdata !== '0) begin
            error_count++;
            $display("ERROR: read %0d request %h/%h strb=%h expected %h/%h",
                     rd_taken, reg_addr, reg_prot, reg_strb, r_addr[rd_taken],
                     r_prot[rd_taken]);
          end
          exp_rdata[rd_taken] <= reg_rdata;
          exp_rresp[rd_taken] <= reg_error ? 2'b10 : 2'b00;
          rd_taken <= rd_taken + 1;
        end
      end
    end
  end

  //---------------------------------------------------------------------------
  // Response monitors
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      b_seen <= 0;
      r_seen <= 0;
    end else begin
      if (bvalid && bready) begin
        check_count++;
        if (b_seen >= wr_taken || bresp !== exp_bresp[b_seen]) begin
          error_count++;
          $display("ERROR: B %0d resp %b expected %b (%0d writes taken)",
                   b_seen, bresp, exp_bresp[b_seen], wr_taken);
        end
        b_seen <= b_seen + 1;
      end
      if (rvalid && rready) begin
        check_count++;
        if (r_seen >= rd_taken || rresp !== exp_rresp[r_seen] ||
            (rresp == 2'b00 && rdata !== exp_rdata[r_seen])) begin
          error_count++;
          $display("ERROR: R %0d %h/%b expected %h/%b", r_seen, rdata, rresp,
                   exp_rdata[r_seen], exp_rresp[r_seen]);
        end
        r_seen <= r_seen + 1;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Manager: one process per channel. Each drives just after an edge and
  // tests its handshake at the negedge, where the values are the ones the
  // next edge will see.
  //---------------------------------------------------------------------------
  initial begin : aw_driver
    awvalid = 1'b0; awaddr = '0; awprot = '0;
    wait (ops_ready && rst_n);
    for (int unsigned i = 0; i < num_writes; i++) begin
      repeat ($urandom_range(0, 4) == 0 ? $urandom_range(1, 5) : 0) begin
        @(posedge clk); #1;
      end
      awvalid = 1'b1; awaddr = w_addr[i]; awprot = w_prot[i];
      forever begin
        @(negedge clk);
        if (awready) break;
        @(posedge clk); #1;
      end
      @(posedge clk); #1;
      awvalid = 1'b0;
    end
  end

  initial begin : w_driver
    wvalid = 1'b0; wdata = '0; wstrb = '0;
    wait (ops_ready && rst_n);
    for (int unsigned i = 0; i < num_writes; i++) begin
      repeat ($urandom_range(0, 4) == 0 ? $urandom_range(1, 5) : 0) begin
        @(posedge clk); #1;
      end
      wvalid = 1'b1; wdata = w_data[i]; wstrb = w_strb[i];
      forever begin
        @(negedge clk);
        if (wready) break;
        @(posedge clk); #1;
      end
      @(posedge clk); #1;
      wvalid = 1'b0;
    end
  end

  initial begin : ar_driver
    arvalid = 1'b0; araddr = '0; arprot = '0;
    wait (ops_ready && rst_n);
    for (int unsigned i = 0; i < num_reads; i++) begin
      repeat ($urandom_range(0, 4) == 0 ? $urandom_range(1, 5) : 0) begin
        @(posedge clk); #1;
      end
      arvalid = 1'b1; araddr = r_addr[i]; arprot = r_prot[i];
      forever begin
        @(negedge clk);
        if (arready) break;
        @(posedge clk); #1;
      end
      @(posedge clk); #1;
      arvalid = 1'b0;
    end
  end

  initial begin : response_ready
    bready = 1'b0; rready = 1'b0;
    forever begin
      @(posedge clk); #1;
      bready = ($urandom_range(0, 3) != 0);
      rready = ($urandom_range(0, 3) != 0);
    end
  end

  //---------------------------------------------------------------------------
  // Sequence
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    check_count = 0;
    ops_ready   = 1'b0;
    num_writes  = 0;
    num_reads   = 0;
    for (int unsigned i = 0; i < NUM_OPS; i++) begin
      if ($urandom_range(0, 1) == 1) begin
        w_addr[num_writes] = ADDR_WIDTH'($urandom());
        w_data[num_writes] = $urandom();
        w_strb[num_writes] = STRB_WIDTH'($urandom());
        w_prot[num_writes] = 3'($urandom());
        num_writes++;
      end else begin
        r_addr[num_reads] = ADDR_WIDTH'($urandom());
        r_prot[num_reads] = 3'($urandom());
        num_reads++;
      end
    end
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    ops_ready = 1'b1;

    wait (b_seen == num_writes && r_seen == num_reads);
    repeat (5) @(posedge clk);
    check_count++;
    if (bvalid || rvalid || reg_valid) begin
      error_count++;
      $display("ERROR: activity after the last response");
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_axi4_lite_slave (%0d checks, %0d writes, %0d reads)",
               check_count, num_writes, num_reads);
      $finish;
    end else begin
      $display("TEST FAILED: tb_axi4_lite_slave, %0d error(s) in %0d checks",
               error_count, check_count);
      $fatal(1, "tb_axi4_lite_slave failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 400000);
    $fatal(1, "tb_axi4_lite_slave: global timeout (%0d/%0d B, %0d/%0d R)",
           b_seen, num_writes, r_seen, num_reads);
  end

endmodule

`default_nettype wire
