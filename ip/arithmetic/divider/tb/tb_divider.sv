//=============================================================================
// Testbench   : tb_divider
// Description : Self-checking SystemVerilog testbench for divider.
//
// The Python-free smoke test. It runs on any SystemVerilog simulator, which
// makes it the fastest signal during development and the fallback when cocotb
// is not available. The exhaustive directed, randomised and regression suites
// live in cocotb/test_divider.py.
//
// The reference is SystemVerilog's own `/` and `%`, which follow the truncated
// convention the block implements: the quotient rounds towards zero and the
// remainder takes the sign of the dividend. The two special cases - division
// by zero and most-negative / -1 - have no arithmetic answer and are checked
// against the documented conventions instead.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed. The driver
// treats a missing banner as a failure, so a testbench that dies early cannot
// be mistaken for a pass.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_divider;

  localparam int unsigned WIDTH      = 8;
  localparam int unsigned SIGNED     = 1;
  localparam time         CLK_PERIOD = 10ns;
  localparam int unsigned NUM_RANDOM = 500;

  localparam logic [WIDTH-1:0] MASK          = {WIDTH{1'b1}};
  localparam logic [WIDTH-1:0] MOST_NEGATIVE = {1'b1, {(WIDTH-1){1'b0}}};

  logic             clk;
  logic             rst_n;
  logic             s_valid;
  logic             s_ready;
  logic [WIDTH-1:0] dividend;
  logic [WIDTH-1:0] divisor;
  logic             m_valid;
  logic             m_ready;
  logic [WIDTH-1:0] quotient;
  logic [WIDTH-1:0] remainder;
  logic             div_by_zero;
  logic             overflow;

  int unsigned      error_count;
  int unsigned      check_count;

  //---------------------------------------------------------------------------
  // Device under test
  //---------------------------------------------------------------------------
  divider #(
      .WIDTH  (WIDTH),
      .SIGNED (SIGNED)
  ) dut (
      .clk         (clk),
      .rst_n       (rst_n),
      .s_valid     (s_valid),
      .s_ready     (s_ready),
      .dividend    (dividend),
      .divisor     (divisor),
      .m_valid     (m_valid),
      .m_ready     (m_ready),
      .quotient    (quotient),
      .remainder   (remainder),
      .div_by_zero (div_by_zero),
      .overflow    (overflow)
  );

  //---------------------------------------------------------------------------
  // Clock
  //---------------------------------------------------------------------------
  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Reference model
  //---------------------------------------------------------------------------
  task automatic model(input  logic [WIDTH-1:0] n,
                       input  logic [WIDTH-1:0] d,
                       output logic [WIDTH-1:0] q,
                       output logic [WIDTH-1:0] r,
                       output logic             dz,
                       output logic             ov);
    dz = (d == '0);
    ov = (SIGNED != 0) && (n == MOST_NEGATIVE) && (d == MASK);

    if (dz) begin
      q = MASK;                   // all-ones quotient
      r = n;                      // the dividend, untouched
    end else if (ov) begin
      q = MOST_NEGATIVE;          // the wrapped value; overflow says why
      r = '0;
    end else if (SIGNED != 0) begin
      q = WIDTH'(signed'(n) / signed'(d));
      r = WIDTH'(signed'(n) % signed'(d));
    end else begin
      q = n / d;
      r = n % d;
    end
  endtask

  //---------------------------------------------------------------------------
  // One division through the ready/valid interfaces
  //---------------------------------------------------------------------------
  task automatic divide(input logic [WIDTH-1:0] n,
                        input logic [WIDTH-1:0] d,
                        input int unsigned      stall_cycles = 0);
    logic [WIDTH-1:0] want_q;
    logic [WIDTH-1:0] want_r;
    logic             want_dz;
    logic             want_ov;
    int unsigned      waited;

    @(negedge clk);
    dividend = n;
    divisor  = d;
    s_valid  = 1'b1;
    do begin
      @(posedge clk);
    end while (s_ready !== 1'b1);
    @(negedge clk);
    s_valid = 1'b0;

    // Optionally hold the result back to exercise the presentation stall.
    m_ready = (stall_cycles == 0);

    waited = 0;
    while (m_valid !== 1'b1) begin
      @(negedge clk);
      waited++;
      if (waited > WIDTH + 8) begin
        error_count++;
        $error("divide 0x%0h / 0x%0h: no result after %0d cycles", n, d, waited);
        return;
      end
    end

    model(n, d, want_q, want_r, want_dz, want_ov);
    check_count++;

    // The result must be held, unchanged, for as long as the sink stalls.
    for (int unsigned i = 0; i <= stall_cycles; i++) begin
      if (quotient !== want_q || remainder !== want_r ||
          div_by_zero !== want_dz || overflow !== want_ov) begin
        error_count++;
        $error({"0x%0h / 0x%0h (stall %0d): expected q=0x%0h r=0x%0h dz=%0b ov=%0b, ",
                "got q=0x%0h r=0x%0h dz=%0b ov=%0b"},
               n, d, i, want_q, want_r, want_dz, want_ov,
               quotient, remainder, div_by_zero, overflow);
      end
      if (m_valid !== 1'b1) begin
        error_count++;
        $error("0x%0h / 0x%0h: m_valid dropped during a stall", n, d);
      end
      if (i < stall_cycles) begin
        @(negedge clk);
      end
    end

    m_ready = 1'b1;
    @(posedge clk);
  endtask

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    error_count = 0;
    check_count = 0;
    rst_n       = 1'b0;
    s_valid     = 1'b0;
    dividend    = '0;
    divisor     = '0;
    m_ready     = 1'b1;

    // --- reset -------------------------------------------------------------
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    #1;
    if (m_valid !== 1'b0 || s_ready !== 1'b1) begin
      error_count++;
      $error("reset: expected m_valid=0 s_ready=1, got %0b %0b", m_valid, s_ready);
    end

    // --- directed: exact, with remainder, by one, zero dividend ------------
    divide(WIDTH'(42), WIDTH'(6));
    divide(WIDTH'(43), WIDTH'(6));
    divide(WIDTH'(77), WIDTH'(1));
    divide('0, WIDTH'(5));
    divide(WIDTH'(5), WIDTH'(7));                 // divisor larger than dividend

    // --- directed: the four sign combinations -------------------------------
    divide(WIDTH'(7),  WIDTH'(2));
    divide(-WIDTH'(7), WIDTH'(2));                // -3 r -1, not -4 r 1
    divide(WIDTH'(7),  -WIDTH'(2));
    divide(-WIDTH'(7), -WIDTH'(2));

    // --- directed: the special cases ----------------------------------------
    divide(WIDTH'(99), '0);                       // division by zero
    divide(MOST_NEGATIVE, '0);
    divide(MOST_NEGATIVE, MASK);                  // most negative / -1
    divide(MOST_NEGATIVE, WIDTH'(1));
    divide(MOST_NEGATIVE, MOST_NEGATIVE);

    // --- directed: a stalled presentation holds the result ------------------
    divide(WIDTH'(100), WIDTH'(7), 5);

    // --- exhaustive sweep, affordable at this width -------------------------
    for (int unsigned n = 0; n <= int'(MASK); n++) begin
      for (int unsigned d = 0; d <= int'(MASK); d += 3) begin
        divide(WIDTH'(n), WIDTH'(d));
      end
    end

    // --- randomised, with random result stalls ------------------------------
    for (int unsigned i = 0; i < NUM_RANDOM; i++) begin
      divide(WIDTH'($urandom()), WIDTH'($urandom()), $urandom_range(0, 3));
    end

    // --- verdict ------------------------------------------------------------
    if (error_count == 0) begin
      $display("TEST PASSED: tb_divider (%0d divisions, WIDTH=%0d SIGNED=%0d)",
               check_count, WIDTH, SIGNED);
      $finish;
    end else begin
      $display("TEST FAILED: tb_divider, %0d error(s) in %0d divisions",
               error_count, check_count);
      $fatal(1, "tb_divider failed");
    end
  end

  //---------------------------------------------------------------------------
  // Global timeout so a hung simulation fails instead of running forever
  //---------------------------------------------------------------------------
  initial begin
    #(CLK_PERIOD * 2000000);
    $fatal(1, "tb_divider: global timeout");
  end

endmodule

`default_nettype wire
