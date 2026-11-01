//=============================================================================
// Testbench   : tb_sha256
// Description : Self-checking SystemVerilog testbench for sha256.
//
// The Python-free smoke test. It hashes the FIPS 180-4 example messages
// against their published digests - "abc", the 448-bit message and one
// million repetitions of "a" - and then 300 random messages of 0 to 300
// bytes against a reference written the textbook way: the message padded
// into a byte array up front, then each block expanded into all 64 schedule
// words before its 64 rounds. The design pads on the fly and keeps a
// 16-word schedule window, so the two share no structure. Words arrive with
// random gaps and the digest sink applies random back-pressure. The full
// suite lives in cocotb/test_sha256.py.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_sha256;

  localparam time         CLK_PERIOD = 10ns;
  localparam int unsigned N_RANDOM   = 300;

  logic         clk;
  logic         rst_n;
  logic         s_valid, s_ready, s_last;
  logic [31:0]  s_data;
  logic [2:0]   s_nbytes;
  logic         m_valid, m_ready;
  logic [255:0] m_digest;

  logic [255:0] expected [$];
  int unsigned  received;
  int unsigned  stall_pct;

  int unsigned error_count;
  int unsigned check_count;

  sha256 dut (
      .clk      (clk),
      .rst_n    (rst_n),
      .s_valid  (s_valid),
      .s_ready  (s_ready),
      .s_data   (s_data),
      .s_last   (s_last),
      .s_nbytes (s_nbytes),
      .m_valid  (m_valid),
      .m_ready  (m_ready),
      .m_digest (m_digest)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Reference: FIPS 180-4 read literally
  //---------------------------------------------------------------------------
  localparam logic [31:0] K [64] = '{
      32'h428a2f98, 32'h71374491, 32'hb5c0fbcf, 32'he9b5dba5, 32'h3956c25b, 32'h59f111f1,
      32'h923f82a4, 32'hab1c5ed5, 32'hd807aa98, 32'h12835b01, 32'h243185be, 32'h550c7dc3,
      32'h72be5d74, 32'h80deb1fe, 32'h9bdc06a7, 32'hc19bf174, 32'he49b69c1, 32'hefbe4786,
      32'h0fc19dc6, 32'h240ca1cc, 32'h2de92c6f, 32'h4a7484aa, 32'h5cb0a9dc, 32'h76f988da,
      32'h983e5152, 32'ha831c66d, 32'hb00327c8, 32'hbf597fc7, 32'hc6e00bf3, 32'hd5a79147,
      32'h06ca6351, 32'h14292967, 32'h27b70a85, 32'h2e1b2138, 32'h4d2c6dfc, 32'h53380d13,
      32'h650a7354, 32'h766a0abb, 32'h81c2c92e, 32'h92722c85, 32'ha2bfe8a1, 32'ha81a664b,
      32'hc24b8b70, 32'hc76c51a3, 32'hd192e819, 32'hd6990624, 32'hf40e3585, 32'h106aa070,
      32'h19a4c116, 32'h1e376c08, 32'h2748774c, 32'h34b0bcb5, 32'h391c0cb3, 32'h4ed8aa4a,
      32'h5b9cca4f, 32'h682e6ff3, 32'h748f82ee, 32'h78a5636f, 32'h84c87814, 32'h8cc70208,
      32'h90befffa, 32'ha4506ceb, 32'hbef9a3f7, 32'hc67178f2};

  function automatic logic [31:0] ror(input logic [31:0] x, input int n);
    return (x >> n) | (x << (32 - n));
  endfunction

  function automatic logic [255:0] reference(input byte unsigned msg[]);
    byte unsigned p[];
    longint unsigned bits;
    int unsigned  n, padded;
    logic [31:0]  hh [8];
    logic [31:0]  ww [64];
    logic [31:0]  va, vb, vc, vd, ve, vf, vg, vh, x1, x2;
    n      = msg.size();
    padded = ((n + 8) / 64 + 1) * 64;
    p      = new[padded];
    for (int i = 0; i < padded; i++) p[i] = 8'h00;
    for (int i = 0; i < n; i++) p[i] = msg[i];
    p[n] = 8'h80;
    bits = longint'(n) * 8;
    for (int i = 0; i < 8; i++) p[padded - 1 - i] = byte'(bits >> (8 * i));
    hh = '{32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
           32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};
    for (int blk = 0; blk < padded / 64; blk++) begin
      for (int t = 0; t < 16; t++) begin
        ww[t] = {p[64*blk + 4*t], p[64*blk + 4*t + 1], p[64*blk + 4*t + 2], p[64*blk + 4*t + 3]};
      end
      for (int t = 16; t < 64; t++) begin
        ww[t] = (ror(ww[t-2], 17) ^ ror(ww[t-2], 19) ^ (ww[t-2] >> 10)) + ww[t-7]
              + (ror(ww[t-15], 7) ^ ror(ww[t-15], 18) ^ (ww[t-15] >> 3)) + ww[t-16];
      end
      {va, vb, vc, vd, ve, vf, vg, vh} = {hh[0], hh[1], hh[2], hh[3], hh[4], hh[5], hh[6], hh[7]};
      for (int t = 0; t < 64; t++) begin
        x1 = vh + (ror(ve, 6) ^ ror(ve, 11) ^ ror(ve, 25)) + ((ve & vf) ^ (~ve & vg)) + K[t] + ww[t];
        x2 = (ror(va, 2) ^ ror(va, 13) ^ ror(va, 22)) + ((va & vb) ^ (va & vc) ^ (vb & vc));
        vh = vg; vg = vf; vf = ve; ve = vd + x1;
        vd = vc; vc = vb; vb = va; va = x1 + x2;
      end
      hh[0] += va; hh[1] += vb; hh[2] += vc; hh[3] += vd;
      hh[4] += ve; hh[5] += vf; hh[6] += vg; hh[7] += vh;
    end
    return {hh[0], hh[1], hh[2], hh[3], hh[4], hh[5], hh[6], hh[7]};
  endfunction

  //---------------------------------------------------------------------------
  // Digest check
  //---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n && m_valid && m_ready) begin
      check_count++;
      if (expected.size() == 0) begin
        error_count++;
        $display("ERROR: digest with no message");
      end else begin
        automatic logic [255:0] want = expected.pop_front();
        if (m_digest !== want) begin
          error_count++;
          $display("ERROR: digest %0d is %h, expected %h", received, m_digest, want);
        end
      end
      received++;
    end
  end

  always @(posedge clk) m_ready <= ($urandom_range(0, 99) >= stall_pct);

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  task automatic send_word(input logic [31:0] data, input logic last,
                           input logic [2:0] nbytes, input int unsigned gap_pct);
    while ($urandom_range(0, 99) < gap_pct) begin
      s_valid = 1'b0;
      @(posedge clk); #1;
    end
    s_valid  = 1'b1;
    s_data   = data;
    s_last   = last;
    s_nbytes = nbytes;
    forever begin
      @(negedge clk);
      if (s_ready) break;
      @(posedge clk); #1;
    end
    @(posedge clk); #1;
    s_valid = 1'b0;
  endtask

  task automatic send(input byte unsigned msg[], input int unsigned gap_pct);
    int unsigned n = msg.size();
    int unsigned i = 0;
    expected.push_back(reference(msg));
    while (n - i > 4) begin
      send_word({msg[i], msg[i+1], msg[i+2], msg[i+3]}, 1'b0, 3'($urandom_range(0, 7)), gap_pct);
      i += 4;
    end
    begin
      logic [31:0] tail = $urandom();
      for (int k = 0; k < 4; k++) if (i + k < n) tail[31 - 8*k -: 8] = msg[i + k];
      send_word(tail, 1'b1, 3'(n - i), gap_pct);
    end
  endtask

  task automatic send_string(input string s, input logic [255:0] digest);
    byte unsigned msg[];
    msg = new[s.len()];
    for (int i = 0; i < s.len(); i++) msg[i] = s[i];
    check_count++;
    if (reference(msg) !== digest) begin
      error_count++;
      $display("ERROR: the reference disagrees with the published digest of \"%s\"", s);
    end
    send(msg, 0);
  endtask

  task automatic wait_idle();
    while (expected.size() != 0) @(posedge clk);
    repeat (2) @(posedge clk);
    #1;
  endtask

  initial begin
    error_count = 0;
    check_count = 0;
    received    = 0;
    stall_pct   = 0;
    s_valid = 1'b0; s_data = '0; s_last = 1'b0; s_nbytes = '0;
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;

    // Published digests.
    send_string("abc", 256'hba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad);
    send_string("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                256'h248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1);
    begin
      byte unsigned million[];
      million = new[1000000];
      for (int i = 0; i < 1000000; i++) million[i] = "a";
      check_count++;
      if (reference(million) !==
          256'hcdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0) begin
        error_count++;
        $display("ERROR: the reference disagrees with the million-a digest");
      end
      send(million, 0);
    end
    wait_idle();

    // Random messages, gaps and back-pressure.
    for (int m = 0; m < N_RANDOM; m++) begin
      byte unsigned msg[];
      msg = new[$urandom_range(0, 300)];
      foreach (msg[i]) msg[i] = byte'($urandom());
      stall_pct = (m < N_RANDOM / 2) ? 0 : 60;
      send(msg, (m % 3 == 0) ? 0 : 30);
    end
    stall_pct = 0;
    wait_idle();

    check_count++;
    if (expected.size() != 0) begin
      error_count++;
      $display("ERROR: %0d digests never arrived", expected.size());
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_sha256 (%0d checks, %0d digests)", check_count, received);
      $finish;
    end else begin
      $display("TEST FAILED: tb_sha256, %0d error(s) in %0d checks", error_count, check_count);
      $fatal(1, "tb_sha256 failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 3000000);
    $fatal(1, "tb_sha256: global timeout");
  end

endmodule

`default_nettype wire
