//=============================================================================
// Testbench   : tb_aes128
// Description : Self-checking SystemVerilog testbench for aes128.
//
// The Python-free smoke test. A reference written from FIPS-197 in plain
// behavioural code - the S-box built at time zero by searching for each
// byte's inverse in GF(2**8), the eleven round keys expanded up front, the
// state as sixteen bytes - checks every output. The FIPS-197 appendix B and
// C.1 vectors are run first and checked against their published values;
// then 1500 random blocks in both directions, under keys that change every
// few blocks, with random gaps and random back-pressure. The full suite
// lives in cocotb/test_aes128.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_aes128;

  localparam time         CLK_PERIOD = 10ns;
  localparam int unsigned N_RANDOM   = 1500;

  logic         clk;
  logic         rst_n;
  logic         key_valid, key_ready;
  logic [127:0] key;
  logic         s_valid, s_ready, s_decrypt;
  logic [127:0] s_data;
  logic         m_valid, m_ready;
  logic [127:0] m_data;

  logic [127:0] expected [$];
  int unsigned  received;
  int unsigned  stall_pct;

  int unsigned error_count;
  int unsigned check_count;

  aes128 #(.DECRYPT(1)) dut (
      .clk       (clk),
      .rst_n     (rst_n),
      .key_valid (key_valid),
      .key_ready (key_ready),
      .key       (key),
      .s_valid   (s_valid),
      .s_ready   (s_ready),
      .s_data    (s_data),
      .s_decrypt (s_decrypt),
      .m_valid   (m_valid),
      .m_ready   (m_ready),
      .m_data    (m_data)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Reference
  //---------------------------------------------------------------------------
  byte unsigned sbox [256];
  byte unsigned inv_sbox [256];

  function automatic byte unsigned gm(input byte unsigned a, input byte unsigned b);
    byte unsigned r = 0;
    for (int i = 0; i < 8; i++) begin
      if (b[0]) r ^= a;
      a = (a[7]) ? ((a << 1) ^ 8'h1b) : (a << 1);
      b >>= 1;
    end
    return r;
  endfunction

  function automatic byte unsigned rol8(input byte unsigned v, input int n);
    return (v << n) | (v >> (8 - n));
  endfunction

  task automatic build_sbox();
    for (int x = 0; x < 256; x++) begin
      byte unsigned inv = 0;
      for (int y = 1; y < 256; y++) if (gm(byte'(x), byte'(y)) == 8'h01) inv = byte'(y);
      sbox[x] = inv ^ rol8(inv, 1) ^ rol8(inv, 2) ^ rol8(inv, 3) ^ rol8(inv, 4) ^ 8'h63;
    end
    for (int x = 0; x < 256; x++) inv_sbox[sbox[x]] = byte'(x);
  endtask

  typedef byte unsigned block_t [16];

  function automatic block_t to_bytes(input logic [127:0] v);
    block_t b;
    for (int i = 0; i < 16; i++) b[i] = v[127 - 8*i -: 8];
    return b;
  endfunction

  function automatic logic [127:0] from_bytes(input block_t b);
    logic [127:0] v;
    for (int i = 0; i < 16; i++) v[127 - 8*i -: 8] = b[i];
    return v;
  endfunction

  function automatic void round_keys(input logic [127:0] k, output logic [127:0] rk [11]);
    byte unsigned w [44][4];
    byte unsigned t [4];
    byte unsigned rc = 8'h01;
    block_t kb = to_bytes(k);
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) w[i][j] = kb[4*i + j];
    for (int i = 4; i < 44; i++) begin
      for (int j = 0; j < 4; j++) t[j] = w[i-1][j];
      if (i % 4 == 0) begin
        t = '{sbox[w[i-1][1]] ^ rc, sbox[w[i-1][2]], sbox[w[i-1][3]], sbox[w[i-1][0]]};
        rc = gm(rc, 8'h02);
      end
      for (int j = 0; j < 4; j++) w[i][j] = w[i-4][j] ^ t[j];
    end
    for (int r = 0; r < 11; r++) begin
      block_t b;
      for (int i = 0; i < 16; i++) b[i] = w[4*r + i/4][i%4];
      rk[r] = from_bytes(b);
    end
  endfunction

  function automatic logic [127:0] reference(input logic [127:0] k, input logic [127:0] din,
                                             input logic dec);
    logic [127:0] rk [11];
    block_t s, o;
    round_keys(k, rk);
    s = to_bytes(din ^ (dec ? rk[10] : rk[0]));
    for (int n = 1; n <= 10; n++) begin
      if (!dec) begin
        for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++)
          o[r + 4*c] = sbox[s[r + 4*((c + r) % 4)]];
        s = o;
        if (n != 10) begin
          for (int c = 0; c < 4; c++) begin
            o[4*c]     = gm(s[4*c], 2) ^ gm(s[4*c+1], 3) ^ s[4*c+2] ^ s[4*c+3];
            o[4*c + 1] = s[4*c] ^ gm(s[4*c+1], 2) ^ gm(s[4*c+2], 3) ^ s[4*c+3];
            o[4*c + 2] = s[4*c] ^ s[4*c+1] ^ gm(s[4*c+2], 2) ^ gm(s[4*c+3], 3);
            o[4*c + 3] = gm(s[4*c], 3) ^ s[4*c+1] ^ s[4*c+2] ^ gm(s[4*c+3], 2);
          end
          s = o;
        end
        s = to_bytes(from_bytes(s) ^ rk[n]);
      end else begin
        for (int r = 0; r < 4; r++) for (int c = 0; c < 4; c++)
          o[r + 4*c] = inv_sbox[s[r + 4*((c + 4 - r) % 4)]];
        s = to_bytes(from_bytes(o) ^ rk[10 - n]);
        if (n != 10) begin
          for (int c = 0; c < 4; c++) begin
            o[4*c]     = gm(s[4*c], 14) ^ gm(s[4*c+1], 11) ^ gm(s[4*c+2], 13) ^ gm(s[4*c+3], 9);
            o[4*c + 1] = gm(s[4*c], 9) ^ gm(s[4*c+1], 14) ^ gm(s[4*c+2], 11) ^ gm(s[4*c+3], 13);
            o[4*c + 2] = gm(s[4*c], 13) ^ gm(s[4*c+1], 9) ^ gm(s[4*c+2], 14) ^ gm(s[4*c+3], 11);
            o[4*c + 3] = gm(s[4*c], 11) ^ gm(s[4*c+1], 13) ^ gm(s[4*c+2], 9) ^ gm(s[4*c+3], 14);
          end
          s = o;
        end
      end
    end
    return from_bytes(s);
  endfunction

  //---------------------------------------------------------------------------
  // Output check
  //---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n && m_valid && m_ready) begin
      check_count++;
      if (expected.size() == 0) begin
        error_count++;
        $display("ERROR: output with no block");
      end else begin
        automatic logic [127:0] want = expected.pop_front();
        if (m_data !== want) begin
          error_count++;
          $display("ERROR: block %0d is %h, expected %h", received, m_data, want);
        end
      end
      received++;
    end
  end

  always @(posedge clk) m_ready <= ($urandom_range(0, 99) >= stall_pct);

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  logic [127:0] current_key;

  task automatic load_key(input logic [127:0] k);
    key_valid = 1'b1;
    key       = k;
    forever begin
      @(negedge clk);
      if (key_ready) break;
      @(posedge clk); #1;
    end
    @(posedge clk); #1;
    key_valid   = 1'b0;
    current_key = k;
  endtask

  task automatic send(input logic [127:0] din, input logic dec, input int unsigned gap_pct);
    while ($urandom_range(0, 99) < gap_pct) begin
      s_valid = 1'b0;
      @(posedge clk); #1;
    end
    s_valid   = 1'b1;
    s_data    = din;
    s_decrypt = dec;
    forever begin
      @(negedge clk);
      if (s_ready) break;
      @(posedge clk); #1;
    end
    expected.push_back(reference(current_key, din, dec));
    @(posedge clk); #1;
    s_valid = 1'b0;
  endtask

  task automatic known(input logic [127:0] k, input logic [127:0] p, input logic [127:0] c);
    check_count += 2;
    if (reference(k, p, 1'b0) !== c || reference(k, c, 1'b1) !== p) begin
      error_count++;
      $display("ERROR: the reference disagrees with FIPS-197 for key %h", k);
    end
    load_key(k);
    send(p, 1'b0, 0);
    send(c, 1'b1, 0);
  endtask

  initial begin
    error_count = 0;
    check_count = 0;
    received    = 0;
    stall_pct   = 0;
    key_valid = 1'b0; key = '0;
    s_valid = 1'b0; s_data = '0; s_decrypt = 1'b0;
    build_sbox();
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;

    known(128'h2b7e151628aed2a6abf7158809cf4f3c, 128'h3243f6a8885a308d313198a2e0370734,
          128'h3925841d02dc09fbdc118597196a0b32);
    known(128'h000102030405060708090a0b0c0d0e0f, 128'h00112233445566778899aabbccddeeff,
          128'h69c4e0d86a7b0430d8cdb78070b4c55a);

    for (int n = 0; n < N_RANDOM; n++) begin
      if (n % 5 == 0) load_key({$urandom(), $urandom(), $urandom(), $urandom()});
      stall_pct = (n < N_RANDOM / 2) ? 0 : 50;
      send({$urandom(), $urandom(), $urandom(), $urandom()}, 1'($urandom_range(0, 1)),
           (n % 3 == 0) ? 0 : 30);
    end
    stall_pct = 0;
    while (expected.size() != 0) @(posedge clk);
    repeat (2) @(posedge clk);

    if (error_count == 0) begin
      $display("TEST PASSED: tb_aes128 (%0d checks)", check_count);
      $finish;
    end else begin
      $display("TEST FAILED: tb_aes128, %0d error(s) in %0d checks", error_count, check_count);
      $fatal(1, "tb_aes128 failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 200000);
    $fatal(1, "tb_aes128: global timeout");
  end

endmodule

`default_nettype wire
