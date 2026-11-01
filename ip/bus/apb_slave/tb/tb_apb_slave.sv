//=============================================================================
// Testbench   : tb_apb_slave
// Description : Self-checking SystemVerilog testbench for apb_slave.
//
// The Python-free smoke test, and the one place both response modes run:
// instance 0 is REGISTERED=0 and instance 1 is REGISTERED=1, each behind its
// own register block with pseudo-random wait states and an error word. The
// same transfer sequence goes through each, and every transfer is checked for
// exactly one register request, its response, and the mode's latency. The
// full suite lives in cocotb/test_apb_slave.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_apb_slave;

  localparam int unsigned ADDR_WIDTH = 6;
  localparam int unsigned DATA_WIDTH = 32;
  localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8;
  localparam int unsigned WORDS      = 1 << (ADDR_WIDTH - 2);
  localparam int unsigned ERROR_WORD = WORDS - 1;
  localparam time         CLK_PERIOD = 10ns;
  localparam int unsigned NUM_RANDOM = 1500;

  logic clk;
  logic rst_n;

  logic [1:0]                    psel, penable, pwrite, pready, pslverr;
  logic [1:0][ADDR_WIDTH-1:0]    paddr;
  logic [1:0][DATA_WIDTH-1:0]    pwdata, prdata;
  logic [1:0][STRB_WIDTH-1:0]    pstrb;
  logic [1:0][2:0]               pprot;

  logic [1:0]                    reg_valid, reg_ready, reg_write, reg_error;
  logic [1:0][ADDR_WIDTH-1:0]    reg_addr;
  logic [1:0][DATA_WIDTH-1:0]    reg_wdata, reg_rdata;
  logic [1:0][STRB_WIDTH-1:0]    reg_strb;
  logic [1:0][2:0]               reg_prot;

  // Register blocks and their bookkeeping, one per instance.
  logic [DATA_WIDTH-1:0] mem      [2][WORDS];
  logic [DATA_WIDTH-1:0] shadow   [2][WORDS];
  int unsigned           accepted [2];
  int unsigned           accept_cycle [2];
  logic [15:0]           lfsr [2];
  int unsigned           cycle = 0;

  int unsigned error_count;
  int unsigned check_count;

  for (genvar i = 0; i < 2; i++) begin : g_dut
    apb_slave #(
        .ADDR_WIDTH (ADDR_WIDTH),
        .DATA_WIDTH (DATA_WIDTH),
        .REGISTERED (i)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .psel      (psel[i]),
        .penable   (penable[i]),
        .pwrite    (pwrite[i]),
        .paddr     (paddr[i]),
        .pwdata    (pwdata[i]),
        .pstrb     (pstrb[i]),
        .pprot     (pprot[i]),
        .pready    (pready[i]),
        .prdata    (prdata[i]),
        .pslverr   (pslverr[i]),
        .reg_valid (reg_valid[i]),
        .reg_ready (reg_ready[i]),
        .reg_write (reg_write[i]),
        .reg_addr  (reg_addr[i]),
        .reg_wdata (reg_wdata[i]),
        .reg_strb  (reg_strb[i]),
        .reg_prot  (reg_prot[i]),
        .reg_rdata (reg_rdata[i]),
        .reg_error (reg_error[i])
    );

    // The register block: combinational read, a wait state whenever the
    // LFSR's low bits are zero, and one word that always errors.
    always_comb begin
      reg_ready[i] = (lfsr[i][1:0] != 2'b00);
      reg_rdata[i] = mem[i][reg_addr[i][ADDR_WIDTH-1:2]];
      reg_error[i] = (reg_addr[i][ADDR_WIDTH-1:2] == ERROR_WORD[ADDR_WIDTH-3:0]);
    end
  end

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  // Both register blocks' state in one process, so no array has two drivers.
  // cycle counts edges: after edge k it holds k, and a request accepted on
  // edge k records k - 1, the value it sees.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < 2; i++) begin
        lfsr[i]     <= 16'hACE1 + 16'(i);
        accepted[i] <= 0;
        for (int w = 0; w < WORDS; w++) mem[i][w] <= '0;
      end
    end else begin
      for (int i = 0; i < 2; i++) begin
        lfsr[i] <= {lfsr[i][14:0], lfsr[i][15] ^ lfsr[i][13] ^ lfsr[i][12] ^ lfsr[i][10]};
        if (reg_valid[i] && reg_ready[i]) begin
          accepted[i]     <= accepted[i] + 1;
          accept_cycle[i] <= cycle;
          if (reg_write[i] && !reg_error[i]) begin
            for (int b = 0; b < STRB_WIDTH; b++) begin
              if (reg_strb[i][b]) mem[i][reg_addr[i][ADDR_WIDTH-1:2]][8*b +: 8]
                  <= reg_wdata[i][8*b +: 8];
            end
          end
        end
      end
    end
  end

  always_ff @(posedge clk) cycle <= cycle + 1;

  task automatic fail(input string msg);
    error_count++;
    $display("ERROR @%0t: %s", $time, msg);
  endtask

  task automatic expect_eq(input int unsigned d, input logic [DATA_WIDTH-1:0] got,
                           input logic [DATA_WIDTH-1:0] exp, input string what);
    check_count++;
    if (got !== exp) fail($sformatf("dut%0d %s: got %h expected %h", d, what, got, exp));
  endtask

  // One APB transfer on instance d, driven just after each edge.
  task automatic transfer(input int unsigned d, input logic wr,
                          input logic [ADDR_WIDTH-1:0] a,
                          input logic [DATA_WIDTH-1:0] data,
                          input logic [STRB_WIDTH-1:0] strb,
                          input logic [2:0] prot);
    automatic int unsigned start_count = accepted[d];
    automatic int unsigned waited = 0;
    automatic logic [DATA_WIDTH-1:0] got_rdata;
    automatic logic got_err;
    automatic int unsigned done_cycle;
    automatic int unsigned word = int'(a[ADDR_WIDTH-1:2]);

    psel[d] = 1'b1; penable[d] = 1'b0; pwrite[d] = wr; paddr[d] = a;
    pwdata[d] = wr ? data : '0; pstrb[d] = wr ? strb : '0; pprot[d] = prot;
    @(posedge clk); #1;
    penable[d] = 1'b1;
    // Inputs change just after an edge, so the values at the negedge are the
    // ones the next edge sees. done_cycle, taken there, is the completing
    // edge's index minus one, the same convention as accept_cycle.
    forever begin
      @(negedge clk);
      if (pready[d]) break;
      if (++waited > 64) begin
        fail($sformatf("dut%0d transfer to %h never completed", d, a));
        break;
      end
      @(posedge clk); #1;
    end
    got_rdata  = prdata[d];
    got_err    = pslverr[d];
    done_cycle = cycle;
    @(posedge clk); #1;
    psel[d] = 1'b0; penable[d] = 1'b0;

    check_count++;
    if (accepted[d] != start_count + 1) begin
      fail($sformatf("dut%0d %h: %0d register requests for one transfer",
                     d, a, accepted[d] - start_count));
    end
    check_count++;
    if (done_cycle - accept_cycle[d] != d) begin
      fail($sformatf("dut%0d %h: completed %0d cycles after acceptance, expected %0d",
                     d, a, done_cycle - accept_cycle[d], d));
    end
    expect_eq(d, 32'(got_err), 32'(word == ERROR_WORD), "PSLVERR");
    if (!wr) begin
      expect_eq(d, got_rdata, shadow[d][word], "PRDATA");
    end else if (word != ERROR_WORD) begin
      for (int b = 0; b < STRB_WIDTH; b++) begin
        if (strb[b]) shadow[d][word][8*b +: 8] = data[8*b +: 8];
      end
    end
  endtask

  task automatic both(input logic wr, input logic [ADDR_WIDTH-1:0] a,
                      input logic [DATA_WIDTH-1:0] data,
                      input logic [STRB_WIDTH-1:0] strb, input int unsigned gap);
    for (int unsigned d = 0; d < 2; d++) begin
      repeat (gap) begin @(posedge clk); #1; end
      transfer(d, wr, a, data, strb, 3'(d + 1));
    end
  endtask

  initial begin
    error_count = 0;
    check_count = 0;
    psel = '0; penable = '0; pwrite = '0; paddr = '0; pwdata = '0;
    pstrb = '0; pprot = '0;
    for (int d = 0; d < 2; d++) begin
      for (int w = 0; w < WORDS; w++) shadow[d][w] = '0;
    end
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk); #1;

    // --- directed ----------------------------------------------------------
    for (int w = 0; w < WORDS; w++) both(1'b1, ADDR_WIDTH'(4 * w), 32'hA5000000 | w, '1, 0);
    for (int w = 0; w < WORDS; w++) both(1'b0, ADDR_WIDTH'(4 * w), '0, '0, 0);
    for (int b = 0; b < STRB_WIDTH; b++) both(1'b1, '0, '0, STRB_WIDTH'(1 << b), 1);
    both(1'b0, '0, '0, '0, 0);

    // --- randomised --------------------------------------------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      both(1'($urandom_range(0, 1)), ADDR_WIDTH'($urandom()), $urandom(),
           STRB_WIDTH'($urandom()), $urandom_range(0, 2));
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_apb_slave (%0d checks, both REGISTERED modes)",
               check_count);
      $finish;
    end else begin
      $display("TEST FAILED: tb_apb_slave, %0d error(s) in %0d checks",
               error_count, check_count);
      $fatal(1, "tb_apb_slave failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 400000);
    $fatal(1, "tb_apb_slave: global timeout");
  end

endmodule

`default_nettype wire
