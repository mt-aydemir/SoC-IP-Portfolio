//=============================================================================
// Module      : sha256
// Category    : crypto
// Description : SHA-256 (FIPS 180-4) over a 32-bit word stream, one round
//               per cycle, with the message padding done in hardware.
//
// INPUT
//   The message arrives as big-endian 32-bit words: the first message byte
//   is s_data[31:24]. Every word but the last carries four bytes. The last
//   word, marked by s_last, carries s_nbytes of them (0 to 4, from the top;
//   values above 4 count as 4), so any byte length is accepted, the empty
//   message included - a lone s_last word with s_nbytes = 0. Bytes below
//   s_nbytes in the last word are ignored.
//
// PADDING
//   The block appends what FIPS 180-4 section 5.1.1 prescribes: a 1 bit (the
//   byte 0x80), zeros up to 56 bytes into a block, and the message length in
//   bits as a 64-bit big-endian number. When the message ends 56 or more
//   bytes into a block the padding spills into one more block. The length
//   counter is 64 bits wide, so messages up to 2**61 - 1 bytes are hashed
//   correctly.
//
// STRUCTURE
//   One round per cycle on the eight working variables a..h. Round t < 16
//   uses message word t directly, so those rounds run as the words arrive -
//   loading and hashing overlap - and rounds 16..63 take their word from
//   the message schedule
//
//     W[t] = s1(W[t-2]) + W[t-7] + s0(W[t-15]) + W[t-16]
//
//   kept in a 16-word shift register. One more cycle adds the working
//   variables into the hash value H, which is also the next block's
//   starting state. A block takes 65 cycles when its words arrive back to
//   back; padding words are generated at one per cycle.
//
// OUTPUT
//   m_digest is H0 in bits 255:224 down to H7 in bits 31:0 - the usual
//   big-endian digest, first byte on top. It is held from m_valid until
//   m_ready. The next message is accepted while a digest waits; its last
//   block stalls before the final addition until the previous digest has
//   been taken.
//
// Latency     : 65 cycles per block; the digest is valid on the cycle after
//               the final block's last round.
// Reset       : asynchronous assertion, synchronous release, active low.
//               H at the initial value, no message in progress, output
//               empty.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module sha256 (
    input  wire          clk,
    input  wire          rst_n,

    // Message words
    input  wire          s_valid,
    output logic         s_ready,
    input  wire  [31:0]  s_data,
    input  wire          s_last,
    input  wire  [2:0]   s_nbytes,

    // Digest
    output logic         m_valid,
    input  wire          m_ready,
    output logic [255:0] m_digest
);

  //---------------------------------------------------------------------------
  // Constants (FIPS 180-4 sections 4.2.2 and 5.3.3)
  //---------------------------------------------------------------------------
  function automatic logic [31:0] round_k(input logic [5:0] t);
    logic [31:0] k;
    begin
      unique case (t)
      6'd0 : k = 32'h428a2f98;
      6'd1 : k = 32'h71374491;
      6'd2 : k = 32'hb5c0fbcf;
      6'd3 : k = 32'he9b5dba5;
      6'd4 : k = 32'h3956c25b;
      6'd5 : k = 32'h59f111f1;
      6'd6 : k = 32'h923f82a4;
      6'd7 : k = 32'hab1c5ed5;
      6'd8 : k = 32'hd807aa98;
      6'd9 : k = 32'h12835b01;
      6'd10: k = 32'h243185be;
      6'd11: k = 32'h550c7dc3;
      6'd12: k = 32'h72be5d74;
      6'd13: k = 32'h80deb1fe;
      6'd14: k = 32'h9bdc06a7;
      6'd15: k = 32'hc19bf174;
      6'd16: k = 32'he49b69c1;
      6'd17: k = 32'hefbe4786;
      6'd18: k = 32'h0fc19dc6;
      6'd19: k = 32'h240ca1cc;
      6'd20: k = 32'h2de92c6f;
      6'd21: k = 32'h4a7484aa;
      6'd22: k = 32'h5cb0a9dc;
      6'd23: k = 32'h76f988da;
      6'd24: k = 32'h983e5152;
      6'd25: k = 32'ha831c66d;
      6'd26: k = 32'hb00327c8;
      6'd27: k = 32'hbf597fc7;
      6'd28: k = 32'hc6e00bf3;
      6'd29: k = 32'hd5a79147;
      6'd30: k = 32'h06ca6351;
      6'd31: k = 32'h14292967;
      6'd32: k = 32'h27b70a85;
      6'd33: k = 32'h2e1b2138;
      6'd34: k = 32'h4d2c6dfc;
      6'd35: k = 32'h53380d13;
      6'd36: k = 32'h650a7354;
      6'd37: k = 32'h766a0abb;
      6'd38: k = 32'h81c2c92e;
      6'd39: k = 32'h92722c85;
      6'd40: k = 32'ha2bfe8a1;
      6'd41: k = 32'ha81a664b;
      6'd42: k = 32'hc24b8b70;
      6'd43: k = 32'hc76c51a3;
      6'd44: k = 32'hd192e819;
      6'd45: k = 32'hd6990624;
      6'd46: k = 32'hf40e3585;
      6'd47: k = 32'h106aa070;
      6'd48: k = 32'h19a4c116;
      6'd49: k = 32'h1e376c08;
      6'd50: k = 32'h2748774c;
      6'd51: k = 32'h34b0bcb5;
      6'd52: k = 32'h391c0cb3;
      6'd53: k = 32'h4ed8aa4a;
      6'd54: k = 32'h5b9cca4f;
      6'd55: k = 32'h682e6ff3;
      6'd56: k = 32'h748f82ee;
      6'd57: k = 32'h78a5636f;
      6'd58: k = 32'h84c87814;
      6'd59: k = 32'h8cc70208;
      6'd60: k = 32'h90befffa;
      6'd61: k = 32'ha4506ceb;
      6'd62: k = 32'hbef9a3f7;
      6'd63: k = 32'hc67178f2;
      endcase
      round_k = k;
    end
  endfunction

  localparam logic [255:0] IV = {
      32'h6a09e667, 32'hbb67ae85, 32'h3c6ef372, 32'ha54ff53a,
      32'h510e527f, 32'h9b05688c, 32'h1f83d9ab, 32'h5be0cd19};

  function automatic logic [31:0] rotr(input logic [31:0] x, input int unsigned n);
    rotr = (x >> n) | (x << (32 - n));
  endfunction

  function automatic logic [31:0] big_sigma0(input logic [31:0] x);
    big_sigma0 = rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22);
  endfunction
  function automatic logic [31:0] big_sigma1(input logic [31:0] x);
    big_sigma1 = rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25);
  endfunction
  function automatic logic [31:0] small_sigma0(input logic [31:0] x);
    small_sigma0 = rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3);
  endfunction
  function automatic logic [31:0] small_sigma1(input logic [31:0] x);
    small_sigma1 = rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10);
  endfunction

  //---------------------------------------------------------------------------
  // Control state
  //---------------------------------------------------------------------------
  logic [5:0]  t;            // round within the block
  logic        finalize;     // the H addition cycle
  logic        pad;          // the message has ended; words are generated
  logic        need_80;      // the 0x80 byte is still to be emitted
  logic        hi_done;      // the length's high word is in this block
  logic        last_block;   // this block ends with the length
  logic [60:0] nbytes_total; // message length in bytes

  logic [31:0] w [16];       // W[t-16] in w[0] .. W[t-1] in w[15]
  logic [31:0] a, b, c, d, e, f, g, h;
  logic [31:0] hv [8];

  //---------------------------------------------------------------------------
  // The word for round t < 16: from the input, or generated padding
  //---------------------------------------------------------------------------
  logic [2:0]  n_last, n_word;
  logic [31:0] keep_mask, one_bit, msg_word, pad_word, feed_word;
  logic        feed_valid, take;
  logic [63:0] length_bits;

  assign n_last      = (s_nbytes > 3'd4) ? 3'd4 : s_nbytes;
  assign keep_mask   = ~(32'hFFFF_FFFF >> (8 * n_last));
  assign n_word      = s_last ? n_last : 3'd4;
  assign one_bit     = (n_last == 3'd4) ? 32'h0 : (32'h8000_0000 >> (8 * n_last));
  assign msg_word    = s_last ? ((s_data & keep_mask) | one_bit) : s_data;
  assign length_bits = {nbytes_total, 3'b000};

  always_comb begin
    if (need_80)                     pad_word = 32'h8000_0000;
    else if (t == 6'd14)             pad_word = length_bits[63:32];
    else if (t == 6'd15 && hi_done)  pad_word = length_bits[31:0];
    else                             pad_word = 32'h0;
  end

  assign s_ready    = !finalize && t < 6'd16 && !pad;
  assign take       = s_valid && s_ready;
  assign feed_valid = pad || take;
  assign feed_word  = pad ? pad_word : msg_word;

  //---------------------------------------------------------------------------
  // One round
  //---------------------------------------------------------------------------
  logic [31:0] sched_word, wt, t1, t2, ch, maj;
  logic        fire;

  assign sched_word = small_sigma1(w[14]) + w[9] + small_sigma0(w[1]) + w[0];
  assign wt         = (t < 6'd16) ? feed_word : sched_word;
  assign ch         = (e & f) ^ (~e & g);
  assign maj        = (a & b) ^ (a & c) ^ (b & c);
  assign t1         = h + big_sigma1(e) + ch + round_k(t) + wt;
  assign t2         = big_sigma0(a) + maj;
  assign fire       = !finalize && (t >= 6'd16 || feed_valid);

  // The final addition waits for a pending digest only at a message's end.
  logic        add_go;
  logic [31:0] sum [8];

  assign add_go = finalize && !(last_block && m_valid && !m_ready);
  assign sum[0] = hv[0] + a;
  assign sum[1] = hv[1] + b;
  assign sum[2] = hv[2] + c;
  assign sum[3] = hv[3] + d;
  assign sum[4] = hv[4] + e;
  assign sum[5] = hv[5] + f;
  assign sum[6] = hv[6] + g;
  assign sum[7] = hv[7] + h;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      t            <= '0;
      finalize     <= 1'b0;
      pad          <= 1'b0;
      need_80      <= 1'b0;
      hi_done      <= 1'b0;
      last_block   <= 1'b0;
      nbytes_total <= '0;
      {a, b, c, d, e, f, g, h} <= IV;
      for (int i = 0; i < 8; i++) hv[i] <= IV[255 - 32*i -: 32];
      for (int i = 0; i < 16; i++) w[i] <= '0;
      m_valid      <= 1'b0;
      m_digest     <= '0;
    end else begin
      if (m_valid && m_ready) m_valid <= 1'b0;

      if (take) begin
        nbytes_total <= nbytes_total + 61'(n_word);
        if (s_last) begin
          pad     <= 1'b1;
          need_80 <= (n_last == 3'd4);
        end
      end
      if (pad && !finalize && t < 6'd16) begin
        if (need_80)                         need_80    <= 1'b0;
        else if (t == 6'd14)                 hi_done    <= 1'b1;
        else if (t == 6'd15 && hi_done)      last_block <= 1'b1;
      end

      if (fire) begin
        for (int i = 0; i < 15; i++) w[i] <= w[i+1];
        w[15] <= wt;
        h <= g;
        g <= f;
        f <= e;
        e <= d + t1;
        d <= c;
        c <= b;
        b <= a;
        a <= t1 + t2;
        t <= t + 6'd1;
        if (t == 6'd63) finalize <= 1'b1;
      end

      if (add_go) begin
        finalize <= 1'b0;
        hi_done  <= 1'b0;
        if (last_block) begin
          m_digest     <= {sum[0], sum[1], sum[2], sum[3], sum[4], sum[5], sum[6], sum[7]};
          m_valid      <= 1'b1;
          last_block   <= 1'b0;
          pad          <= 1'b0;
          nbytes_total <= '0;
          {a, b, c, d, e, f, g, h} <= IV;
          for (int i = 0; i < 8; i++) hv[i] <= IV[255 - 32*i -: 32];
        end else begin
          {a, b, c, d, e, f, g, h} <= {sum[0], sum[1], sum[2], sum[3],
                                       sum[4], sum[5], sum[6], sum[7]};
          for (int i = 0; i < 8; i++) hv[i] <= sum[i];
        end
      end
    end
  end

  //---------------------------------------------------------------------------
  // Checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  property p_digest_held;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready) |=> (m_valid && $stable(m_digest));
  endproperty
  a_digest_held : assert property (p_digest_held)
    else $error("sha256: digest changed before m_ready");

  property p_no_input_while_padding;
    @(posedge clk) disable iff (!rst_n) pad |-> !s_ready;
  endproperty
  a_no_input_while_padding : assert property (p_no_input_while_padding)
    else $error("sha256: input accepted after the last word");
`endif

endmodule

`default_nettype wire
