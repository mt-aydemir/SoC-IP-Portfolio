//=============================================================================
// Testbench   : tb_mac_array
// Description : Self-checking SystemVerilog testbench for mac_array.
//
// The Python-free smoke test, at a configuration the cocotb run does not
// use: five lanes - not a power of two, so the adder tree is padded - six-bit
// operands, unsigned activations against signed weights, and the narrowest
// legal accumulator, sixteen bits, so long vectors wrap. A reference that
// sums every product in a 64-bit integer and reduces modulo 2**16 at the end
// checks every result. Vectors of 1 to 40 beats arrive with random gaps and
// the sink applies random back-pressure. The full suite lives in
// cocotb/test_mac_array.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_mac_array;

  localparam int unsigned LANES      = 5;
  localparam int unsigned DATA_WIDTH = 6;
  localparam int unsigned ACC_WIDTH  = 2 * DATA_WIDTH + 1 + $clog2(LANES);
  localparam int unsigned N_VECTORS  = 3000;
  localparam time         CLK_PERIOD = 10ns;

  logic                         clk;
  logic                         rst_n;
  logic                         s_valid, s_ready, s_last;
  logic [LANES*DATA_WIDTH-1:0]  s_a, s_b;
  logic                         m_valid, m_ready;
  logic [ACC_WIDTH-1:0]         m_data;

  logic [ACC_WIDTH-1:0] expected [$];
  longint               partial;
  int unsigned          received;
  int unsigned          stall_pct;
  int unsigned          wrapped;

  int unsigned error_count;
  int unsigned check_count;

  mac_array #(
      .LANES      (LANES),
      .DATA_WIDTH (DATA_WIDTH),
      .ACC_WIDTH  (ACC_WIDTH),
      .A_SIGNED   (0),
      .B_SIGNED   (1)
  ) dut (
      .clk     (clk),
      .rst_n   (rst_n),
      .s_valid (s_valid),
      .s_ready (s_ready),
      .s_a     (s_a),
      .s_b     (s_b),
      .s_last  (s_last),
      .m_valid (m_valid),
      .m_ready (m_ready),
      .m_data  (m_data)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  // The reference: unsigned a, signed b, summed exactly.
  function automatic longint beat_value(input logic [LANES*DATA_WIDTH-1:0] a,
                                        input logic [LANES*DATA_WIDTH-1:0] b);
    longint sum = 0;
    for (int i = 0; i < LANES; i++) begin
      automatic longint ua = longint'({1'b0, a[i*DATA_WIDTH +: DATA_WIDTH]});
      automatic longint sb = longint'($signed(b[i*DATA_WIDTH +: DATA_WIDTH]));
      sum += ua * sb;
    end
    return sum;
  endfunction

  always @(posedge clk) begin
    if (rst_n) begin
      if (m_valid && m_ready) begin
        check_count++;
        if (expected.size() == 0) begin
          error_count++;
          $display("ERROR: result with no vector");
        end else begin
          automatic logic [ACC_WIDTH-1:0] want = expected.pop_front();
          if (m_data !== want) begin
            error_count++;
            $display("ERROR: result %0d is %h, expected %h", received, m_data, want);
          end
        end
        received++;
      end
      if (s_valid && s_ready) begin
        partial += beat_value(s_a, s_b);
        if (s_last) begin
          if (partial >= (longint'(1) <<< (ACC_WIDTH - 1)) ||
              partial < -(longint'(1) <<< (ACC_WIDTH - 1))) wrapped++;
          expected.push_back(ACC_WIDTH'(partial));
          partial = 0;
        end
      end
    end
  end

  always @(posedge clk) m_ready <= ($urandom_range(0, 99) >= stall_pct);

  task automatic send_beat(input logic last, input int unsigned gap_pct, input logic extreme);
    while ($urandom_range(0, 99) < gap_pct) begin
      s_valid = 1'b0;
      s_a     = (LANES*DATA_WIDTH)'({$urandom(), $urandom()});    // junk while idle
      @(posedge clk); #1;
    end
    s_valid = 1'b1;
    s_last  = last;
    if (extreme) begin
      s_a = '1;                                   // largest unsigned
      s_b = {LANES{1'b1, {(DATA_WIDTH-1){1'b0}}}}; // most negative signed
    end else begin
      s_a = (LANES*DATA_WIDTH)'({$urandom(), $urandom()});
      s_b = (LANES*DATA_WIDTH)'({$urandom(), $urandom()});
    end
    forever begin
      @(negedge clk);
      if (s_ready) break;
      @(posedge clk); #1;
    end
    @(posedge clk); #1;
    s_valid = 1'b0;
  endtask

  initial begin
    error_count = 0;
    check_count = 0;
    received    = 0;
    partial     = 0;
    wrapped     = 0;
    stall_pct   = 0;
    s_valid = 1'b0; s_last = 1'b0; s_a = '0; s_b = '0;
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;

    for (int v = 0; v < N_VECTORS; v++) begin
      automatic int unsigned beats   = $urandom_range(1, 40);
      automatic logic        extreme = (v % 10 == 0);
      stall_pct = (v < N_VECTORS / 2) ? 0 : 40;
      for (int n = 0; n < beats; n++) begin
        send_beat(n == beats - 1, (v % 3 == 0) ? 0 : 25, extreme);
      end
    end
    stall_pct = 0;
    while (expected.size() != 0) @(posedge clk);
    repeat (2) @(posedge clk);

    check_count++;
    if (wrapped == 0) begin
      error_count++;
      $display("ERROR: no vector exercised the wrap");
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_mac_array (%0d checks, %0d wrapped)", check_count, wrapped);
      $finish;
    end else begin
      $display("TEST FAILED: tb_mac_array, %0d error(s) in %0d checks", error_count, check_count);
      $fatal(1, "tb_mac_array failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 400000);
    $fatal(1, "tb_mac_array: global timeout");
  end

endmodule

`default_nettype wire
