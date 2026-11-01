//=============================================================================
// Module      : lfsr_rng
// Category    : crypto
// Description : Maximal-length linear-feedback shift register as a
//               pseudo-random bit source: STEPS fresh bits per draw, a
//               run-time seed, and a stream output.
//
// NOT A CRYPTOGRAPHIC GENERATOR. An LFSR is linear: 2*WIDTH consecutive
// output bits determine the whole sequence (Berlekamp-Massey recovers it).
// It is the right tool for test patterns, scramblers, dithering, BIST and
// randomised arbitration, and the wrong one for keys, nonces or masks.
//
// SEQUENCE
//   Fibonacci form over the bits b[t] of the sequence:
//
//     b[t] = XOR over k in TAPS(WIDTH) of b[t-k]
//
//   The state holds the last WIDTH bits, b[t-1] in bit 0 and b[t-WIDTH] in
//   bit WIDTH-1, and a step shifts the new bit in at bit 0. TAPS(WIDTH) is
//   the table below (Xilinx XAPP052), one primitive feedback polynomial per
//   width, so the state visits every non-zero value: the period is
//   2**WIDTH - 1. The all-zero state would repeat forever and is never
//   entered.
//
// DRAWS
//   A draw advances the register STEPS times in one cycle - the STEPS-fold
//   composition of the step is still a set of XORs - and m_data is the low
//   STEPS bits of the state: the STEPS bits just generated, the newest in
//   bit 0. Consecutive draws are therefore consecutive, non-overlapping
//   STEPS-bit pieces of the one sequence. With STEPS = 1 the draws are the
//   sequence itself.
//
// INTERFACE
//   m_valid is high from the first cycle after reset; a draw is consumed on
//   every edge with m_ready high, and the next one is ready on the next
//   cycle. seed_load replaces the state with seed and generates the first
//   draw from it; m_data on the following cycle is that draw. A zero seed
//   is replaced by 1, the one value that cannot be used. seed_load wins
//   over m_ready: a draw taken on the same edge is the last of the old
//   sequence.
//
// Parameters
//   WIDTH  State width, and log2 of the period plus one. 2 to 64.
//   STEPS  Bits per draw. 1 to WIDTH.
//   SEED   State loaded at reset (zero is replaced by 1). Its low WIDTH bits
//          are used.
//
// Latency     : one cycle from seed_load to the first draw.
// Reset       : asynchronous assertion, synchronous release, active low.
//               The state is SEED advanced by one draw, m_valid low until
//               the first edge after release.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module lfsr_rng #(
    parameter int unsigned    WIDTH = 32,
    parameter int unsigned    STEPS = 8,
    parameter logic [63:0]    SEED  = 64'd1
) (
    input  wire               clk,
    input  wire               rst_n,

    // Seed port
    input  wire               seed_load,
    input  wire  [WIDTH-1:0]  seed,

    // Draws
    output logic              m_valid,
    input  wire               m_ready,
    output logic [STEPS-1:0]  m_data
);

  //---------------------------------------------------------------------------
  // Feedback taps: bit k-1 set for each tap k of the XAPP052 table. Every
  // entry is a primitive polynomial; the cocotb suite recovers the
  // polynomial from the output and checks it.
  //---------------------------------------------------------------------------
  function automatic logic [63:0] lfsr_taps(input int unsigned w);
    begin
      unique case (w)
       2: lfsr_taps = 64'h0000000000000003;  // 2, 1
       3: lfsr_taps = 64'h0000000000000006;  // 3, 2
       4: lfsr_taps = 64'h000000000000000c;  // 4, 3
       5: lfsr_taps = 64'h0000000000000014;  // 5, 3
       6: lfsr_taps = 64'h0000000000000030;  // 6, 5
       7: lfsr_taps = 64'h0000000000000060;  // 7, 6
       8: lfsr_taps = 64'h00000000000000b8;  // 8, 6, 5, 4
       9: lfsr_taps = 64'h0000000000000110;  // 9, 5
      10: lfsr_taps = 64'h0000000000000240;  // 10, 7
      11: lfsr_taps = 64'h0000000000000500;  // 11, 9
      12: lfsr_taps = 64'h0000000000000829;  // 12, 6, 4, 1
      13: lfsr_taps = 64'h000000000000100d;  // 13, 4, 3, 1
      14: lfsr_taps = 64'h0000000000002015;  // 14, 5, 3, 1
      15: lfsr_taps = 64'h0000000000006000;  // 15, 14
      16: lfsr_taps = 64'h000000000000d008;  // 16, 15, 13, 4
      17: lfsr_taps = 64'h0000000000012000;  // 17, 14
      18: lfsr_taps = 64'h0000000000020400;  // 18, 11
      19: lfsr_taps = 64'h0000000000040023;  // 19, 6, 2, 1
      20: lfsr_taps = 64'h0000000000090000;  // 20, 17
      21: lfsr_taps = 64'h0000000000140000;  // 21, 19
      22: lfsr_taps = 64'h0000000000300000;  // 22, 21
      23: lfsr_taps = 64'h0000000000420000;  // 23, 18
      24: lfsr_taps = 64'h0000000000e10000;  // 24, 23, 22, 17
      25: lfsr_taps = 64'h0000000001200000;  // 25, 22
      26: lfsr_taps = 64'h0000000002000023;  // 26, 6, 2, 1
      27: lfsr_taps = 64'h0000000004000013;  // 27, 5, 2, 1
      28: lfsr_taps = 64'h0000000009000000;  // 28, 25
      29: lfsr_taps = 64'h0000000014000000;  // 29, 27
      30: lfsr_taps = 64'h0000000020000029;  // 30, 6, 4, 1
      31: lfsr_taps = 64'h0000000048000000;  // 31, 28
      32: lfsr_taps = 64'h0000000080200003;  // 32, 22, 2, 1
      33: lfsr_taps = 64'h0000000100080000;  // 33, 20
      34: lfsr_taps = 64'h0000000204000003;  // 34, 27, 2, 1
      35: lfsr_taps = 64'h0000000500000000;  // 35, 33
      36: lfsr_taps = 64'h0000000801000000;  // 36, 25
      37: lfsr_taps = 64'h000000100000001f;  // 37, 5, 4, 3, 2, 1
      38: lfsr_taps = 64'h0000002000000031;  // 38, 6, 5, 1
      39: lfsr_taps = 64'h0000004400000000;  // 39, 35
      40: lfsr_taps = 64'h000000a000140000;  // 40, 38, 21, 19
      41: lfsr_taps = 64'h0000012000000000;  // 41, 38
      42: lfsr_taps = 64'h00000300000c0000;  // 42, 41, 20, 19
      43: lfsr_taps = 64'h0000063000000000;  // 43, 42, 38, 37
      44: lfsr_taps = 64'h00000c0000030000;  // 44, 43, 18, 17
      45: lfsr_taps = 64'h00001b0000000000;  // 45, 44, 42, 41
      46: lfsr_taps = 64'h0000300003000000;  // 46, 45, 26, 25
      47: lfsr_taps = 64'h0000420000000000;  // 47, 42
      48: lfsr_taps = 64'h0000c00000180000;  // 48, 47, 21, 20
      49: lfsr_taps = 64'h0001008000000000;  // 49, 40
      50: lfsr_taps = 64'h0003000000c00000;  // 50, 49, 24, 23
      51: lfsr_taps = 64'h0006000c00000000;  // 51, 50, 36, 35
      52: lfsr_taps = 64'h0009000000000000;  // 52, 49
      53: lfsr_taps = 64'h0018003000000000;  // 53, 52, 38, 37
      54: lfsr_taps = 64'h0030000000030000;  // 54, 53, 18, 17
      55: lfsr_taps = 64'h0040000040000000;  // 55, 31
      56: lfsr_taps = 64'h00c0000600000000;  // 56, 55, 35, 34
      57: lfsr_taps = 64'h0102000000000000;  // 57, 50
      58: lfsr_taps = 64'h0200004000000000;  // 58, 39
      59: lfsr_taps = 64'h0600003000000000;  // 59, 58, 38, 37
      60: lfsr_taps = 64'h0c00000000000000;  // 60, 59
      61: lfsr_taps = 64'h1800300000000000;  // 61, 60, 46, 45
      62: lfsr_taps = 64'h3000000000000030;  // 62, 61, 6, 5
      63: lfsr_taps = 64'h6000000000000000;  // 63, 62
      64: lfsr_taps = 64'hd800000000000000;  // 64, 63, 61, 60
      default: lfsr_taps = 64'h0;
      endcase
    end
  endfunction

  localparam logic [WIDTH-1:0] TAPS = WIDTH'(lfsr_taps(WIDTH));

  // STEPS steps of the recurrence.
  function automatic logic [WIDTH-1:0] draw(input logic [WIDTH-1:0] s);
    logic [WIDTH-1:0] r;
    begin
      r = s;
      for (int unsigned i = 0; i < STEPS; i++) begin
        r = {r[WIDTH-2:0], ^(r & TAPS)};
      end
      draw = r;
    end
  endfunction

  function automatic logic [WIDTH-1:0] nonzero(input logic [WIDTH-1:0] s);
    nonzero = (s == '0) ? WIDTH'(1) : s;
  endfunction

  localparam logic [WIDTH-1:0] RESET_STATE = draw(nonzero(SEED[WIDTH-1:0]));

  logic [WIDTH-1:0] state;
  logic [WIDTH-1:0] source;

  // One draw network, shared by the seed load and the normal advance.
  assign source = seed_load ? nonzero(seed) : state;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= RESET_STATE;
      m_valid <= 1'b0;
    end else begin
      m_valid <= 1'b1;
      if (seed_load || (m_valid && m_ready)) begin
        state <= draw(source);
      end
    end
  end

  assign m_data = state[STEPS-1:0];

  //---------------------------------------------------------------------------
  // Checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (WIDTH < 2 || WIDTH > 64) begin
      $fatal(1, "lfsr_rng: WIDTH must be 2 to 64 (got %0d)", WIDTH);
    end
    if (STEPS < 1 || STEPS > WIDTH) begin
      $fatal(1, "lfsr_rng: STEPS must be 1 to WIDTH (got %0d)", STEPS);
    end
  end

  property p_never_zero;
    @(posedge clk) disable iff (!rst_n) state != '0;
  endproperty
  a_never_zero : assert property (p_never_zero)
    else $error("lfsr_rng: the state reached zero");

  property p_held;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready && !seed_load) |=> $stable(m_data);
  endproperty
  a_held : assert property (p_held)
    else $error("lfsr_rng: a draw changed before m_ready");
`endif

endmodule

`default_nettype wire
