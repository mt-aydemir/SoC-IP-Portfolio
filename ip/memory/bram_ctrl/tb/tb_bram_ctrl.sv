//=============================================================================
// Testbench   : tb_bram_ctrl
// Description : Self-checking SystemVerilog testbench for bram_ctrl.
//
// Streams requests with randomised back-pressure on the response channel and
// checks the invariant the whole block is built on: exactly one response per
// accepted request, in order, and never a response that arrives with nowhere
// to go.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_bram_ctrl;

  localparam int unsigned DATA_WIDTH = 32;
  localparam int unsigned DEPTH      = 256;
  localparam int unsigned ADDR_WIDTH = $clog2(DEPTH);
  localparam int unsigned NUM_BYTES  = DATA_WIDTH / 8;
  localparam time         CLK_PERIOD = 10ns;

  logic                  clk, rst_n;
  logic                  req_valid, req_ready, req_we;
  logic [ADDR_WIDTH-1:0] req_addr;
  logic [NUM_BYTES-1:0]  req_be;
  logic [DATA_WIDTH-1:0] req_wdata;
  logic                  rsp_valid, rsp_ready, rsp_err;
  logic [DATA_WIDTH-1:0] rsp_rdata;

  int unsigned           error_count;
  int unsigned           issued_count;
  int unsigned           response_count;
  logic                  backpressure_go;

  // Expected read data, in request order. Writes push a don't-care marker so
  // the response count still lines up one to one with requests.
  logic [DATA_WIDTH-1:0] expected      [$];
  logic                  expect_check  [$];

  logic [DATA_WIDTH-1:0] model [DEPTH];

  bram_ctrl #(
      .DATA_WIDTH     (DATA_WIDTH),
      .DEPTH          (DEPTH),
      .WRITE_RESPONSE (1)
  ) dut (
      .clk       (clk),
      .rst_n     (rst_n),
      .req_valid (req_valid),
      .req_ready (req_ready),
      .req_we    (req_we),
      .req_addr  (req_addr),
      .req_be    (req_be),
      .req_wdata (req_wdata),
      .rsp_valid (rsp_valid),
      .rsp_ready (rsp_ready),
      .rsp_rdata (rsp_rdata),
      .rsp_err   (rsp_err)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Response monitor
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n && rsp_valid && rsp_ready) begin
      if (expected.size() == 0) begin
        error_count++;
        $error("unexpected response 0x%0h at %0t", rsp_rdata, $time);
      end else begin
        automatic logic [DATA_WIDTH-1:0] want  = expected.pop_front();
        automatic logic                  check = expect_check.pop_front();
        response_count++;
        if (check && (rsp_rdata !== want)) begin
          error_count++;
          $error("response %0d: expected 0x%0h, got 0x%0h at %0t",
                 response_count, want, rsp_rdata, $time);
        end
        if (rsp_err !== 1'b0) begin
          error_count++;
          $error("response %0d reported an error on a valid address",
                 response_count);
        end
      end
    end
  end

  //---------------------------------------------------------------------------
  // Request driver
  //---------------------------------------------------------------------------
  task automatic issue(input logic we,
                       input logic [ADDR_WIDTH-1:0] a,
                       input logic [DATA_WIDTH-1:0] d,
                       input logic [NUM_BYTES-1:0]  mask);
    @(negedge clk);
    req_valid = 1'b1;
    req_we    = we;
    req_addr  = a;
    req_be    = mask;
    req_wdata = d;
    do begin
      @(posedge clk);
    end while (req_ready !== 1'b1);

    if (we) begin
      for (int unsigned b = 0; b < NUM_BYTES; b++) begin
        if (mask[b]) begin
          model[a][b*8 +: 8] = d[b*8 +: 8];
        end
      end
      expected.push_back('0);
      expect_check.push_back(1'b0);
    end else begin
      expected.push_back(model[a]);
      expect_check.push_back(1'b1);
    end
    issued_count++;

    @(negedge clk);
    req_valid = 1'b0;
  endtask

  //---------------------------------------------------------------------------
  // Response back-pressure, in its own process
  //---------------------------------------------------------------------------
  initial begin : backpressure
    backpressure_go = 1'b0;
    rsp_ready       = 1'b1;
    forever begin
      @(negedge clk);
      if (backpressure_go) begin
        rsp_ready = ($urandom_range(0, 3) != 0);
      end else begin
        rsp_ready = 1'b1;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count    = 0;
    issued_count   = 0;
    response_count = 0;
    req_valid      = 1'b0;
    req_we         = 1'b0;
    req_addr       = '0;
    req_be         = '1;
    req_wdata      = '0;
    rst_n          = 1'b0;

    for (int unsigned i = 0; i < DEPTH; i++) begin
      model[i] = '0;
    end

    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    #1;

    if (req_ready !== 1'b1 || rsp_valid !== 1'b0) begin
      error_count++;
      $error("reset state wrong: req_ready=%0b rsp_valid=%0b",
             req_ready, rsp_valid);
    end

    // --- initialise the array -------------------------------------------------
    for (int unsigned i = 0; i < DEPTH; i++) begin
      issue(1'b1, ADDR_WIDTH'(i), '0, '1);
    end

    // --- write then read back --------------------------------------------------
    issue(1'b1, ADDR_WIDTH'(16), 32'hDEAD_BEEF, '1);
    issue(1'b0, ADDR_WIDTH'(16), '0, '1);

    // --- byte enables ----------------------------------------------------------
    issue(1'b1, ADDR_WIDTH'(17), '0, '1);
    for (int unsigned b = 0; b < NUM_BYTES; b++) begin
      issue(1'b1, ADDR_WIDTH'(17), {DATA_WIDTH{1'b1}}, NUM_BYTES'(1 << b));
      issue(1'b0, ADDR_WIDTH'(17), '0, '1);
    end

    // --- sustained streaming with no stalls -----------------------------------
    for (int unsigned i = 0; i < DEPTH; i++) begin
      issue(1'b1, ADDR_WIDTH'(i), DATA_WIDTH'(i * 32'h0101_0101 + 32'h9E37), '1);
    end
    for (int unsigned i = 0; i < DEPTH; i++) begin
      issue(1'b0, ADDR_WIDTH'(i), '0, '1);
    end

    // --- randomised traffic with response back-pressure ------------------------
    backpressure_go = 1'b1;
    for (int unsigned i = 0; i < 600; i++) begin
      if ($urandom_range(0, 1) == 0) begin
        issue(1'b1, ADDR_WIDTH'($urandom_range(0, DEPTH - 1)),
              DATA_WIDTH'($urandom()),
              NUM_BYTES'($urandom_range(1, (1 << NUM_BYTES) - 1)));
      end else begin
        issue(1'b0, ADDR_WIDTH'($urandom_range(0, DEPTH - 1)), '0, '1);
      end
    end
    backpressure_go = 1'b0;

    // --- drain -----------------------------------------------------------------
    wait (expected.size() == 0);
    repeat (16) @(posedge clk);

    // --- verdict ----------------------------------------------------------------
    if (response_count != issued_count) begin
      error_count++;
      $error("count mismatch: issued %0d requests, saw %0d responses",
             issued_count, response_count);
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_bram_ctrl (%0d requests, %0d x %0d array)",
               issued_count, DEPTH, DATA_WIDTH);
      $finish;
    end else begin
      $display("TEST FAILED: tb_bram_ctrl, %0d error(s)", error_count);
      $fatal(1, "tb_bram_ctrl failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 500000);
    $fatal(1, "tb_bram_ctrl: global timeout");
  end

endmodule

`default_nettype wire
