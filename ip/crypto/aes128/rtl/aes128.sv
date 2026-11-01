//=============================================================================
// Module      : aes128
// Category    : crypto
// Description : AES-128 block cipher (FIPS-197), encryption and decryption,
//               one round per cycle, with the key schedule computed on the
//               fly in both directions.
//
// BYTE ORDER
//   As in FIPS-197: the first byte of a block or key is bits 127:120, and
//   the state is filled column by column, so byte (row r, column c) is
//   bits 127-8*(r+4c) down to 120-8*(r+4c). The FIPS-197 example vectors
//   read as 128-bit hexadecimal numbers apply unchanged.
//
// KEY
//   key_valid / key_ready loads a cipher key. The block needs the last round
//   key to start a decryption, so a key load runs the key schedule forward
//   once, ten cycles, and keeps both the first and the last round key; with
//   DECRYPT = 0 it only stores the key. No block is accepted until a key has
//   been loaded, nor while one is loading, and a key load takes precedence
//   over a block offered on the same cycle. A new key may be loaded between
//   any two blocks.
//
// BLOCKS
//   s_valid / s_ready accepts a block; s_decrypt, sampled with it, selects
//   decryption. Every round key is derived from the previous one in the
//   same cycle as the round that uses it - forward from the first round key
//   when encrypting, backward from the last when decrypting, using
//
//     forward:  n0 = w0 ^ SubWord(RotWord(w3)) ^ Rcon,  n1 = w1 ^ n0,
//               n2 = w2 ^ n1,  n3 = w3 ^ n2
//     backward: w3 = n3 ^ n2,  w2 = n2 ^ n1,  w1 = n1 ^ n0,
//               w0 = n0 ^ SubWord(RotWord(w3)) ^ Rcon
//
//   so no key memory is needed. Encryption is the cipher of FIPS-197
//   section 5.1; decryption the inverse cipher of section 5.3, InvSubBytes,
//   InvShiftRows, AddRoundKey and InvMixColumns in that order.
//
// TIMING
//   The accepting edge applies the initial AddRoundKey; rounds 1 to 10 take
//   one edge each, and m_valid rises after the tenth. The result register
//   is also the round state, so the next block is accepted when the result
//   is taken - on the same edge at the earliest: eleven cycles per block.
//
// Parameters
//   DECRYPT  1 builds the inverse cipher and the backward key schedule; 0
//            leaves them out and ignores s_decrypt.
//
// Latency     : 11 cycles from the accepting edge to m_valid.
// Reset       : asynchronous assertion, synchronous release, active low.
//               No key, no block in progress, output empty.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module aes128 #(
    parameter int unsigned DECRYPT = 1
) (
    input  wire          clk,
    input  wire          rst_n,

    // Cipher key
    input  wire          key_valid,
    output logic         key_ready,
    input  wire  [127:0] key,

    // Input blocks
    input  wire          s_valid,
    output logic         s_ready,
    input  wire  [127:0] s_data,
    input  wire          s_decrypt,

    // Output blocks
    output logic         m_valid,
    input  wire          m_ready,
    output logic [127:0] m_data
);

  //---------------------------------------------------------------------------
  // Byte-level helpers
  //---------------------------------------------------------------------------
  function automatic logic [7:0] get(input logic [127:0] s, input int r, input int c);
    get = s[127 - 8*(r + 4*c) -: 8];
  endfunction

  function automatic logic [127:0] shift_rows(input logic [127:0] s);
    logic [127:0] o;
    for (int r = 0; r < 4; r++)
      for (int c = 0; c < 4; c++)
        o[127 - 8*(r + 4*c) -: 8] = get(s, r, (c + r) % 4);
    shift_rows = o;
  endfunction

  function automatic logic [127:0] inv_shift_rows(input logic [127:0] s);
    logic [127:0] o;
    for (int r = 0; r < 4; r++)
      for (int c = 0; c < 4; c++)
        o[127 - 8*(r + 4*c) -: 8] = get(s, r, (c + 4 - r) % 4);
    inv_shift_rows = o;
  endfunction

  function automatic logic [7:0] xtime(input logic [7:0] x);
    xtime = {x[6:0], 1'b0} ^ (x[7] ? 8'h1b : 8'h00);
  endfunction

  // Multiplication by a constant of at most four bits, enough for 9, b, d, e.
  function automatic logic [7:0] gmul(input logic [7:0] x, input logic [3:0] k);
    logic [7:0] x2, x4, x8;
    x2 = xtime(x);
    x4 = xtime(x2);
    x8 = xtime(x4);
    gmul = (k[0] ? x : 8'h00) ^ (k[1] ? x2 : 8'h00) ^ (k[2] ? x4 : 8'h00) ^ (k[3] ? x8 : 8'h00);
  endfunction

  function automatic logic [127:0] mix_columns(input logic [127:0] s);
    logic [127:0] o;
    logic [7:0]   a0, a1, a2, a3;
    for (int c = 0; c < 4; c++) begin
      a0 = get(s, 0, c); a1 = get(s, 1, c); a2 = get(s, 2, c); a3 = get(s, 3, c);
      o[127 - 32*c -: 8]       = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3;
      o[127 - 32*c - 8 -: 8]   = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3;
      o[127 - 32*c - 16 -: 8]  = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3);
      o[127 - 32*c - 24 -: 8]  = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3);
    end
    mix_columns = o;
  endfunction

  function automatic logic [127:0] inv_mix_columns(input logic [127:0] s);
    logic [127:0] o;
    logic [7:0]   a0, a1, a2, a3;
    for (int c = 0; c < 4; c++) begin
      a0 = get(s, 0, c); a1 = get(s, 1, c); a2 = get(s, 2, c); a3 = get(s, 3, c);
      o[127 - 32*c -: 8]      = gmul(a0, 4'he) ^ gmul(a1, 4'hb) ^ gmul(a2, 4'hd) ^ gmul(a3, 4'h9);
      o[127 - 32*c - 8 -: 8]  = gmul(a0, 4'h9) ^ gmul(a1, 4'he) ^ gmul(a2, 4'hb) ^ gmul(a3, 4'hd);
      o[127 - 32*c - 16 -: 8] = gmul(a0, 4'hd) ^ gmul(a1, 4'h9) ^ gmul(a2, 4'he) ^ gmul(a3, 4'hb);
      o[127 - 32*c - 24 -: 8] = gmul(a0, 4'hb) ^ gmul(a1, 4'hd) ^ gmul(a2, 4'h9) ^ gmul(a3, 4'he);
    end
    inv_mix_columns = o;
  endfunction

  function automatic logic [7:0] rcon(input logic [3:0] i);
    unique case (i)
      4'd1:    rcon = 8'h01;
      4'd2:    rcon = 8'h02;
      4'd3:    rcon = 8'h04;
      4'd4:    rcon = 8'h08;
      4'd5:    rcon = 8'h10;
      4'd6:    rcon = 8'h20;
      4'd7:    rcon = 8'h40;
      4'd8:    rcon = 8'h80;
      4'd9:    rcon = 8'h1b;
      4'd10:   rcon = 8'h36;
      default: rcon = 8'h00;
    endcase
  endfunction

  //---------------------------------------------------------------------------
  // State
  //---------------------------------------------------------------------------
  logic [127:0] key_first;   // round key 0, the cipher key
  logic [127:0] key_last;    // round key 10
  logic         key_ok;      // a key has been loaded
  logic         expanding;   // the key schedule is running forward
  logic         busy;        // rounds 1 to 10 of a block
  logic         decrypting;
  logic [3:0]   round;       // the round, or schedule step, the next edge does
  logic [127:0] rk;          // the round key of the previous round
  logic [127:0] state;

  logic         key_take, block_take;

  assign key_ready  = !busy && !expanding;
  assign key_take   = key_valid && key_ready;
  assign s_ready    = key_ok && !busy && !expanding && !key_valid && (!m_valid || m_ready);
  assign block_take = s_valid && s_ready;
  assign m_data     = state;

  //---------------------------------------------------------------------------
  // Key schedule, one step either way, sharing four S-boxes
  //---------------------------------------------------------------------------
  logic [31:0]  w3_prev, rot, sub_word;
  logic [127:0] rk_next, rk_prev;
  logic [7:0]   rc_next, rc_prev;

  assign w3_prev = rk[31:0] ^ rk[63:32];
  assign rot     = decrypting ? {w3_prev[23:0], w3_prev[31:24]} : {rk[23:0], rk[31:24]};

  for (genvar i = 0; i < 4; i++) begin : g_key_sbox
    aes_sbox u_sbox (.a(rot[8*i +: 8]), .q(sub_word[8*i +: 8]));
  end

  assign rc_next = rcon(round);
  assign rc_prev = rcon(4'd11 - round);

  always_comb begin
    logic [31:0] n0, n1, n2, n3, w0;
    n0 = rk[127:96] ^ sub_word ^ {rc_next, 24'h0};
    n1 = rk[95:64] ^ n0;
    n2 = rk[63:32] ^ n1;
    n3 = rk[31:0] ^ n2;
    rk_next = {n0, n1, n2, n3};
    w0 = rk[127:96] ^ sub_word ^ {rc_prev, 24'h0};
    rk_prev = {w0, rk[127:96] ^ rk[95:64], rk[95:64] ^ rk[63:32], w3_prev};
  end

  //---------------------------------------------------------------------------
  // One round either way
  //---------------------------------------------------------------------------
  logic [127:0] sub_out, enc_shifted, enc_next;
  logic [127:0] inv_out, dec_keyed, dec_next;

  for (genvar i = 0; i < 16; i++) begin : g_sbox
    aes_sbox u_sbox (.a(state[8*i +: 8]), .q(sub_out[8*i +: 8]));
  end

  assign enc_shifted = shift_rows(sub_out);
  assign enc_next    = (round == 4'd10 ? enc_shifted : mix_columns(enc_shifted)) ^ rk_next;

  generate
    if (DECRYPT != 0) begin : g_decrypt
      logic [127:0] inv_in;
      assign inv_in = inv_shift_rows(state);
      for (genvar i = 0; i < 16; i++) begin : g_inv_sbox
        aes_inv_sbox u_inv_sbox (.a(inv_in[8*i +: 8]), .q(inv_out[8*i +: 8]));
      end
    end else begin : g_no_decrypt
      assign inv_out = '0;
    end
  endgenerate

  assign dec_keyed = inv_out ^ rk_prev;
  assign dec_next  = (round == 4'd10) ? dec_keyed : inv_mix_columns(dec_keyed);

  //---------------------------------------------------------------------------
  // Sequencing
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      key_first  <= '0;
      key_last   <= '0;
      key_ok     <= 1'b0;
      expanding  <= 1'b0;
      busy       <= 1'b0;
      decrypting <= 1'b0;
      round      <= '0;
      rk         <= '0;
      state      <= '0;
      m_valid    <= 1'b0;
    end else begin
      if (m_valid && m_ready) m_valid <= 1'b0;

      if (key_take) begin
        key_first  <= key;
        rk         <= key;
        round      <= 4'd1;
        decrypting <= 1'b0;
        key_ok     <= (DECRYPT == 0);
        expanding  <= (DECRYPT != 0);
      end else if (expanding) begin
        rk    <= rk_next;
        round <= round + 4'd1;
        if (round == 4'd10) begin
          key_last  <= rk_next;
          expanding <= 1'b0;
          key_ok    <= 1'b1;
        end
      end else if (block_take) begin
        decrypting <= s_decrypt && (DECRYPT != 0);
        rk         <= (s_decrypt && DECRYPT != 0) ? key_last : key_first;
        state      <= s_data ^ ((s_decrypt && DECRYPT != 0) ? key_last : key_first);
        round      <= 4'd1;
        busy       <= 1'b1;
      end else if (busy) begin
        rk    <= decrypting ? rk_prev : rk_next;
        state <= decrypting ? dec_next : enc_next;
        round <= round + 4'd1;
        if (round == 4'd10) begin
          busy    <= 1'b0;
          m_valid <= 1'b1;
        end
      end
    end
  end

  //---------------------------------------------------------------------------
  // Checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  property p_output_held;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready) |=> (m_valid && $stable(m_data));
  endproperty
  a_output_held : assert property (p_output_held)
    else $error("aes128: output changed before m_ready");

  property p_round_range;
    @(posedge clk) disable iff (!rst_n)
      (busy || expanding) |-> (round >= 4'd1 && round <= 4'd10);
  endproperty
  a_round_range : assert property (p_round_range)
    else $error("aes128: round counter out of range");
`endif

endmodule

`default_nettype wire
