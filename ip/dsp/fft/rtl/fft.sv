//=============================================================================
// Module      : fft
// Category    : dsp
// Description : Burst radix-2 FFT/IFFT of 2**N_LOG2 complex points: load a
//               frame, transform it in place with one butterfly per cycle,
//               unload it in natural order.
//
// A frame of N complex samples is loaded, transformed and unloaded:
//
//   X[k] = (1/N) * sum over n of x[n] * exp(-+ j*2*pi*n*k/N)
//
// with the minus sign for the forward transform and the plus sign when the
// frame was loaded with inverse high. The 1/N is the fixed scaling that
// keeps the arithmetic in range; it makes the inverse transform exact in
// scale, and the forward one off by the usual factor N.
//
// ALGORITHM
//   Decimation in time, in place. Samples are written at bit-reversed
//   addresses as they arrive, so the butterflies leave the result in natural
//   order. Stage s (0 .. N_LOG2-1) pairs points half = 2**s apart; butterfly
//   j of the stage works on
//
//     i0 = (j / half) * 2*half + (j mod half),   i1 = i0 + half
//
//   with twiddle w = exp(-+ j*2*pi*(j mod half) / (2*half)):
//
//     t   = w * x[i1]
//     x[i0] = (x[i0] + t) / 2,   x[i1] = (x[i0] - t) / 2
//
// FIXED POINT
//   Twiddles are Q1.15 from fft_twiddle. The complex product is rounded half
//   up to the data's scale, and each halving is rounded half up too. The
//   halving keeps a real or imaginary part within range except where the
//   rotation lines a vector up with an axis - a sum of two full-scale parts
//   can reach (1 + sqrt 2)/2 of full scale - so each butterfly output is
//   saturated, and m_overflow reports a frame in which any was.
//
// THROUGHPUT
//   A frame takes N cycles to load, (N/2) * N_LOG2 to transform and N to
//   unload under no back-pressure. The block holds one frame: loading the
//   next waits until the current one is unloaded.
//
// INTERFACE
//   Input samples are taken on s_valid && s_ready, N per frame; inverse is
//   sampled with each frame's first sample. Output samples come in natural
//   order with m_last on bin N-1 and m_overflow held for the whole frame.
//
// Parameters
//   N_LOG2      Transform size, N = 2**N_LOG2. 3 to 10.
//   DATA_WIDTH  Signed width of each real and imaginary part. 4 to 24.
//
// Reset       : asynchronous assertion, synchronous release, active low.
//               Ready to load, frame memory contents undefined until loaded.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module fft #(
    parameter int unsigned N_LOG2     = 6,
    parameter int unsigned DATA_WIDTH = 16
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // Input frame, N samples
    input  wire                          s_valid,
    output logic                         s_ready,
    input  wire  signed [DATA_WIDTH-1:0] s_re,
    input  wire  signed [DATA_WIDTH-1:0] s_im,
    input  wire                          inverse,

    // Output frame, natural order
    output logic                         m_valid,
    input  wire                          m_ready,
    output logic signed [DATA_WIDTH-1:0] m_re,
    output logic signed [DATA_WIDTH-1:0] m_im,
    output logic                         m_last,
    output logic                         m_overflow
);

  localparam int unsigned N  = 1 << N_LOG2;
  localparam int unsigned AW = N_LOG2;
  localparam int unsigned SW = (N_LOG2 > 1) ? $clog2(N_LOG2) : 1;
  localparam int unsigned TW = 16;
  localparam int unsigned PW = DATA_WIDTH + TW;        // one product
  localparam int unsigned BW = DATA_WIDTH + 3;         // butterfly sums

  localparam logic signed [BW-1:0] D_MAX = BW'((64'sd1 <<< (DATA_WIDTH - 1)) - 1);
  localparam logic signed [BW-1:0] D_MIN = BW'(-(64'sd1 <<< (DATA_WIDTH - 1)));

  localparam logic [1:0] LOAD    = 2'd0;
  localparam logic [1:0] COMPUTE = 2'd1;
  localparam logic [1:0] UNLOAD  = 2'd2;

  logic [1:0]                   state;
  logic [AW-1:0]                count;      // load / unload position
  logic [SW-1:0]                stage;
  logic [AW-2:0]                bfly;       // butterfly within the stage
  logic                         inverse_q;
  logic                         overflow_q;

  logic signed [DATA_WIDTH-1:0] mem_re [N];
  logic signed [DATA_WIDTH-1:0] mem_im [N];

  //---------------------------------------------------------------------------
  // Addressing
  //---------------------------------------------------------------------------
  function automatic logic [AW-1:0] bit_reverse(input logic [AW-1:0] a);
    logic [AW-1:0] r;
    for (int b = 0; b < AW; b++) r[b] = a[AW-1-b];
    bit_reverse = r;
  endfunction

  logic [AW-1:0] half, pos, i0, i1;
  logic [8:0]    tw_index;

  assign half     = AW'(1) << stage;
  assign pos      = AW'(bfly) & (half - 1'b1);
  assign i0       = ((AW'(bfly) >> stage) << (stage + 1'b1)) | pos;
  assign i1       = i0 | half;
  // pos/(2*half) of a turn is pos << (N_LOG2-1-stage) in N-point units, and
  // the ROM counts in 1024-point units.
  assign tw_index = 9'((10'(pos) << (N_LOG2 - 1 - 32'(stage))) << (10 - N_LOG2));

  //---------------------------------------------------------------------------
  // Butterfly
  //---------------------------------------------------------------------------
  logic signed [TW-1:0] w_cos, w_sin, wr, wi;

  fft_twiddle u_twiddle (
      .k       (tw_index),
      .cos_out (w_cos),
      .sin_out (w_sin)
  );

  // Forward: w = cos - j sin. Inverse: w = cos + j sin.
  assign wr = w_cos;
  assign wi = inverse_q ? w_sin : -w_sin;

  logic signed [DATA_WIDTH-1:0] ar, ai, br, bi;
  logic signed [PW-1:0]         p_rr, p_ii, p_ri, p_ir;
  logic signed [PW:0]           t_re_full, t_im_full;
  logic signed [BW-1:0]         t_re, t_im;
  logic signed [BW-1:0]         s0_re, s0_im, s1_re, s1_im;
  logic signed [BW-1:0]         h0_re, h0_im, h1_re, h1_im;
  logic signed [DATA_WIDTH-1:0] o0_re, o0_im, o1_re, o1_im;
  logic [3:0]                   clip;

  assign ar = mem_re[i0];
  assign ai = mem_im[i0];
  assign br = mem_re[i1];
  assign bi = mem_im[i1];

  // Both operands are signed, so each product is a signed DATA_WIDTH x 16
  // multiply sized to its PW-bit result - exact, and no wider than it needs
  // to be. (Widening the operands to PW first, as the multiplier IP does,
  // builds four PW x PW arrays here.)
  assign p_rr = PW'(br * wr);
  assign p_ii = PW'(bi * wi);
  assign p_ri = PW'(br * wi);
  assign p_ir = PW'(bi * wr);

  // t = w * b, rounded half up from Q1.15 back to the data's scale.
  assign t_re_full = (PW+1)'(p_rr) - (PW+1)'(p_ii) + (PW+1)'(1 << (TW - 2));
  assign t_im_full = (PW+1)'(p_ri) + (PW+1)'(p_ir) + (PW+1)'(1 << (TW - 2));
  assign t_re      = BW'(t_re_full >>> (TW - 1));
  assign t_im      = BW'(t_im_full >>> (TW - 1));

  assign s0_re = BW'(ar) + t_re;
  assign s0_im = BW'(ai) + t_im;
  assign s1_re = BW'(ar) - t_re;
  assign s1_im = BW'(ai) - t_im;

  // Halve, rounding half up.
  assign h0_re = (s0_re + BW'(1)) >>> 1;
  assign h0_im = (s0_im + BW'(1)) >>> 1;
  assign h1_re = (s1_re + BW'(1)) >>> 1;
  assign h1_im = (s1_im + BW'(1)) >>> 1;

  function automatic logic signed [DATA_WIDTH-1:0] saturate(input logic signed [BW-1:0] v);
    saturate = (v > D_MAX) ? DATA_WIDTH'(D_MAX)
             : (v < D_MIN) ? DATA_WIDTH'(D_MIN)
             : DATA_WIDTH'(v);
  endfunction

  assign o0_re = saturate(h0_re);
  assign o0_im = saturate(h0_im);
  assign o1_re = saturate(h1_re);
  assign o1_im = saturate(h1_im);
  assign clip  = {h0_re > D_MAX || h0_re < D_MIN, h0_im > D_MAX || h0_im < D_MIN,
                  h1_re > D_MAX || h1_re < D_MIN, h1_im > D_MAX || h1_im < D_MIN};

  //---------------------------------------------------------------------------
  // Control and memory
  //---------------------------------------------------------------------------
  logic          load_take, unload_take, last_bfly;
  logic [AW-1:0] load_addr;

  assign load_addr = bit_reverse(count);

  assign s_ready     = (state == LOAD);
  assign load_take   = s_valid && s_ready;
  assign m_valid     = (state == UNLOAD);
  assign unload_take = m_valid && m_ready;
  assign last_bfly   = (32'(bfly) == N / 2 - 1);

  assign m_re       = mem_re[count];
  assign m_im       = mem_im[count];
  assign m_last     = (32'(count) == N - 1);
  assign m_overflow = overflow_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= LOAD;
      count      <= '0;
      stage      <= '0;
      bfly       <= '0;
      inverse_q  <= 1'b0;
      overflow_q <= 1'b0;
    end else begin
      unique case (state)
        LOAD: begin
          if (load_take) begin
            if (count == '0) inverse_q <= inverse;
            count <= count + 1'b1;
            if (32'(count) == N - 1) begin
              state      <= COMPUTE;
              stage      <= '0;
              bfly       <= '0;
              overflow_q <= 1'b0;
            end
          end
        end
        COMPUTE: begin
          if (|clip) overflow_q <= 1'b1;
          bfly <= bfly + 1'b1;
          if (last_bfly) begin
            bfly <= '0;
            if (32'(stage) == N_LOG2 - 1) begin
              state <= UNLOAD;
              count <= '0;
            end else begin
              stage <= stage + 1'b1;
            end
          end
        end
        UNLOAD: begin
          if (unload_take) begin
            count <= count + 1'b1;
            if (m_last) state <= LOAD;
          end
        end
        default: state <= LOAD;
      endcase
    end
  end

  // The frame memory has no reset: it is written in full before it is read.
  always_ff @(posedge clk) begin
    if (load_take) begin
      mem_re[load_addr] <= s_re;
      mem_im[load_addr] <= s_im;
    end else if (state == COMPUTE) begin
      mem_re[i0] <= o0_re;
      mem_im[i0] <= o0_im;
      mem_re[i1] <= o1_re;
      mem_im[i1] <= o1_im;
    end
  end

  //---------------------------------------------------------------------------
  // Checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (N_LOG2 < 3 || N_LOG2 > 10) begin
      $fatal(1, "fft: N_LOG2 must be 3 to 10 (got %0d)", N_LOG2);
    end
    if (DATA_WIDTH < 4 || DATA_WIDTH > 24) begin
      $fatal(1, "fft: DATA_WIDTH must be 4 to 24 (got %0d)", DATA_WIDTH);
    end
  end

  property p_output_held;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready) |=> (m_valid && $stable(m_re) && $stable(m_im) && $stable(m_last));
  endproperty
  a_output_held : assert property (p_output_held)
    else $error("fft: output changed before m_ready");
`endif

endmodule

`default_nettype wire
