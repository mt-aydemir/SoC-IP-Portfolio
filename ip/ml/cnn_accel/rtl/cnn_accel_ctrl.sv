//=============================================================================
// Module      : cnn_accel_ctrl
// Category    : ml
// Description : Frame parser and sequencer for cnn_accel. Decodes the command
//               header at the start of each AXI4-Stream frame, routes the
//               payload beats to the weight, parameter or activation path, and
//               owns every rule about when the accelerator may accept them.
//
// The accelerator is driven entirely over its data stream: there is no
// register interface. Each frame is one command - a header beat followed by
// its payload, delimited by TLAST - which means a host with nothing but a DMA
// engine can drive it, and a whole layer can be queued as one descriptor chain
// with no processor involvement between tiles.
//
// HEADER
//   [ 7: 0] opcode
//   [15: 8] flags        COMPUTE: bit 0 = first tile, bit 1 = last tile
//   [31:16] count        payload beats the header claims
//   [39:32] out_zero_point   LOAD_PARAMS only, two's complement
//   [47:40] out_min          LOAD_PARAMS only, two's complement
//   [55:48] out_max          LOAD_PARAMS only, two's complement
//
//   opcode 0x00 NOP            fence, and clears the sticky error
//   opcode 0x01 LOAD_WEIGHTS   ARRAY_N beats, one weight row each
//   opcode 0x02 LOAD_PARAMS    ARRAY_N beats, one channel's requant parameters
//   opcode 0x03 COMPUTE        count activation vectors, count <= ACC_DEPTH
//   opcode 0x04 STATUS         no payload; replies with a two-beat frame
//
// TLAST IS THE DELIMITER, COUNT IS THE CHECK
//   The frame ends where TLAST says it ends, and `count` is compared against
//   it. A mismatch raises the sticky error rather than desynchronising the
//   parser, which is the difference between a driver bug that shows up as one
//   flagged job and one that shows up as every subsequent job being wrong.
//
//   A weight or parameter frame that is the wrong length is not committed at
//   all: half a weight tile is misaligned rather than merely incomplete, and
//   computing with it would produce numbers that look almost right.
//
// WHEN WORK MAY BE ACCEPTED
//   Three rules, and each exists because breaking it corrupts data silently:
//
//   * A weight commit waits for the array to drain. Vectors still inside would
//     finish their accumulation against a mixture of two tiles.
//   * A parameter load waits for the whole pipeline to drain. The requantiser
//     is downstream of the array, so changing its parameters would rescale
//     results that were computed under the old ones.
//   * A COMPUTE frame waits for the previous one to retire before admitting
//     its first vector, because the accumulator addressing and the end-of-frame
//     bookkeeping are per frame.
//
//   Weight *rows* are deliberately not covered by any of those. They go into
//   the shadow registers inside the array, which no multiplier reads, so a
//   tile can be pushed in while the previous frame is still draining. That
//   overlap is the reason the array has a double-buffered weight register at
//   all, and in the normal sequence - load weights, compute, load weights,
//   compute - it hides the drain completely.
//
// Parameters
//   ARRAY_N     Array dimension; also the beat count of a weight or parameter
//               frame.
//   ACC_DEPTH   Accumulator buffer depth, the largest legal COMPUTE count.
//
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module cnn_accel_ctrl #(
    parameter int unsigned ARRAY_N   = 16,
    parameter int unsigned ACC_DEPTH = 256
) (
    input  wire        clk,
    input  wire        rst_n,

    // Command stream, sink side
    input  wire        s_valid,
    output logic       s_ready,
    input  wire        s_last,

    // Header fields, sliced by the parent from the beat being offered. Split
    // into ports rather than passed as one word so that the reserved bits of
    // the header are visibly reserved rather than silently ignored.
    input  wire [7:0]  hdr_opcode,
    input  wire [1:0]  hdr_flags,     // COMPUTE: bit 0 first tile, bit 1 last
    input  wire [15:0] hdr_count,

    // Datapath status
    input  wire        credit_ok,     // room for one more result
    input  wire        pipe_empty,    // no vector between admission and output
    input  wire        array_busy,    // a vector is inside the array
    input  wire        status_room,   // room in the output buffer for a reply

    // Weight path
    output logic       w_beat,
    output logic       w_commit,

    // Requantisation parameter path
    output logic       p_beat,
    output logic [$clog2(ARRAY_N)-1:0] p_index,
    output logic       p_header,      // latch the clamp fields from the header

    // Activation path
    output logic       a_beat,
    output logic       a_frame_first,   // this beat is the frame's first vector
    output logic       a_frame_end,
    output logic       acc_first,     // this tile initialises the accumulator
    output logic       acc_last,      // this tile requantises and emits

    // Status reply
    output logic       status_push,
    output logic       status_index,

    // Observability
    output logic       frame_active,
    output logic       error_flag
);

  localparam int unsigned IDX_WIDTH   = $clog2(ARRAY_N);
  localparam int unsigned COUNT_WIDTH = 16;

  localparam logic [7:0] OP_NOP          = 8'h00;
  localparam logic [7:0] OP_LOAD_WEIGHTS = 8'h01;
  localparam logic [7:0] OP_LOAD_PARAMS  = 8'h02;
  localparam logic [7:0] OP_COMPUTE      = 8'h03;
  localparam logic [7:0] OP_STATUS       = 8'h04;

  typedef enum logic [2:0] {
    S_HDR,
    S_WEIGHT,
    S_WCOMMIT,
    S_PARAM,
    S_COMPUTE,
    S_STATUS
  } state_e;

  state_e state_q;

  logic [COUNT_WIDTH-1:0] beat_q;        // payload beats consumed so far
  logic [COUNT_WIDTH-1:0] count_q;       // the count the header claimed
  logic [COUNT_WIDTH-1:0] chunk_len_q;   // vectors in the accumulation chunk
  logic                   chunk_valid_q;
  logic                   acc_first_q;
  logic                   acc_last_q;
  logic                   commit_ok_q;   // the weight frame was well formed
  logic                   status_beat_q;
  logic                   error_q;

  assign frame_active = (state_q != S_HDR);
  assign error_flag   = error_q;
  assign acc_first    = acc_first_q;
  assign acc_last     = acc_last_q;
  assign p_index      = IDX_WIDTH'(beat_q);
  assign status_index = status_beat_q;

  //---------------------------------------------------------------------------
  // Header decode. Combinational, evaluated on the beat being offered in
  // S_HDR; nothing here has an effect until that beat is accepted.
  //---------------------------------------------------------------------------
  logic hdr_legal;

  always_comb begin
    unique case (hdr_opcode)
      OP_NOP:          hdr_legal = (hdr_count == '0) && s_last;
      OP_STATUS:       hdr_legal = (hdr_count == '0) && s_last;
      OP_LOAD_WEIGHTS: hdr_legal = (hdr_count == COUNT_WIDTH'(ARRAY_N)) && !s_last;
      OP_LOAD_PARAMS:  hdr_legal = (hdr_count == COUNT_WIDTH'(ARRAY_N)) && !s_last;
      OP_COMPUTE:      hdr_legal = (hdr_count != '0) && !s_last &&
                                   (hdr_count <= COUNT_WIDTH'(ACC_DEPTH));
      default:         hdr_legal = 1'b0;
    endcase
  end

  //---------------------------------------------------------------------------
  // Ready generation.
  //
  // A header is always accepted, so an illegal one is consumed and reported
  // rather than stalling the stream behind it. Payload readiness is where the
  // rules live.
  //---------------------------------------------------------------------------
  logic compute_admit;   // this beat is a real vector rather than a surplus one

  assign compute_admit = (beat_q < count_q);

  always_comb begin
    unique case (state_q)
      S_HDR:     s_ready = 1'b1;
      S_WEIGHT:  s_ready = 1'b1;
      S_PARAM:   s_ready = pipe_empty;
      S_COMPUTE: s_ready = compute_admit ? (credit_ok && (beat_q != '0 ||
                                                          pipe_empty))
                                         : 1'b1;
      default:   s_ready = 1'b0;
    endcase
  end

  logic beat_fire;
  assign beat_fire = s_valid && s_ready;

  //---------------------------------------------------------------------------
  // Sequencer
  //---------------------------------------------------------------------------
  always_comb begin
    w_beat        = 1'b0;
    w_commit      = 1'b0;
    p_beat        = 1'b0;
    p_header      = 1'b0;
    a_beat        = 1'b0;
    a_frame_first = 1'b0;
    a_frame_end   = 1'b0;
    status_push   = 1'b0;

    unique case (state_q)
      S_HDR: begin
        if (beat_fire && hdr_legal && (hdr_opcode == OP_LOAD_PARAMS)) begin
          p_header = 1'b1;
        end
      end

      S_WEIGHT: begin
        // Beats past the tile height are consumed and dropped, as is the whole
        // payload of a frame whose header did not parse; the length mismatch
        // is what gets reported.
        w_beat = beat_fire && commit_ok_q && (beat_q < COUNT_WIDTH'(ARRAY_N));
      end

      S_WCOMMIT: begin
        w_commit = commit_ok_q && !array_busy;
      end

      S_PARAM: begin
        p_beat = beat_fire && (beat_q < COUNT_WIDTH'(ARRAY_N));
      end

      S_COMPUTE: begin
        // The frame's own state - accumulator addressing, the vector count
        // used to place TLAST - is reset by the first admitted vector rather
        // than by the header, because a header may be accepted while the
        // previous frame is still draining through the pipeline.
        a_beat        = beat_fire && compute_admit;
        a_frame_first = beat_fire && compute_admit && (beat_q == '0);
        a_frame_end   = beat_fire && s_last;
      end

      S_STATUS: begin
        status_push = status_room;
      end

      default: begin
        status_push = 1'b0;
      end
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q       <= S_HDR;
      beat_q        <= '0;
      count_q       <= '0;
      chunk_len_q   <= '0;
      chunk_valid_q <= 1'b0;
      acc_first_q   <= 1'b0;
      acc_last_q    <= 1'b0;
      commit_ok_q   <= 1'b0;
      status_beat_q <= 1'b0;
      error_q       <= 1'b0;
    end else begin
      unique case (state_q)
        //---------------------------------------------------------------------
        S_HDR: begin
          if (beat_fire) begin
            beat_q  <= '0;
            count_q <= hdr_count;

            if (!hdr_legal) begin
              error_q <= 1'b1;
              // A malformed header with more beats behind it would leave the
              // parser reading payload as commands. Weights are the only
              // payload that is safe to drop blindly, so the frame is treated
              // as a weight frame that will not be committed.
              if (!s_last) begin
                state_q     <= S_WEIGHT;
                commit_ok_q <= 1'b0;
              end
            end else begin
              unique case (hdr_opcode)
                OP_NOP: begin
                  error_q <= 1'b0;
                end
                OP_STATUS: begin
                  state_q       <= S_STATUS;
                  status_beat_q <= 1'b0;
                end
                OP_LOAD_WEIGHTS: begin
                  state_q     <= S_WEIGHT;
                  commit_ok_q <= 1'b1;
                end
                OP_LOAD_PARAMS: begin
                  state_q <= S_PARAM;
                end
                OP_COMPUTE: begin
                  state_q     <= S_COMPUTE;
                  acc_first_q <= hdr_flags[0];
                  acc_last_q  <= hdr_flags[1];
                end
                default: begin
                  state_q <= S_HDR;
                end
              endcase
            end
          end
        end

        //---------------------------------------------------------------------
        S_WEIGHT: begin
          if (beat_fire) begin
            beat_q <= beat_q + COUNT_WIDTH'(1);
            if (s_last) begin
              state_q <= S_WCOMMIT;
              if (beat_q + COUNT_WIDTH'(1) != COUNT_WIDTH'(ARRAY_N)) begin
                error_q     <= 1'b1;
                commit_ok_q <= 1'b0;
              end
            end
          end
        end

        //---------------------------------------------------------------------
        S_WCOMMIT: begin
          if (!array_busy) begin
            state_q <= S_HDR;
          end
        end

        //---------------------------------------------------------------------
        S_PARAM: begin
          if (beat_fire) begin
            beat_q <= beat_q + COUNT_WIDTH'(1);
            if (s_last) begin
              state_q <= S_HDR;
              if (beat_q + COUNT_WIDTH'(1) != COUNT_WIDTH'(ARRAY_N)) begin
                error_q <= 1'b1;
              end
            end
          end
        end

        //---------------------------------------------------------------------
        S_COMPUTE: begin
          if (beat_fire) begin
            if (compute_admit) begin
              beat_q <= beat_q + COUNT_WIDTH'(1);
            end else begin
              // More beats than the header claimed.
              error_q <= 1'b1;
            end

            if (s_last) begin
              state_q <= S_HDR;

              if (compute_admit &&
                  (beat_q + COUNT_WIDTH'(1) != count_q)) begin
                error_q <= 1'b1;     // frame shorter than the header claimed
              end

              // Every tile of an accumulation chunk must present the same
              // number of vectors, or the partial sums in the accumulator
              // belong to different output positions than the ones being
              // added to them.
              if (acc_first_q) begin
                chunk_len_q   <= beat_q + COUNT_WIDTH'(compute_admit);
                chunk_valid_q <= 1'b1;
              end else if (chunk_valid_q &&
                           (chunk_len_q != beat_q +
                                           COUNT_WIDTH'(compute_admit))) begin
                error_q <= 1'b1;
              end

              if (acc_last_q) begin
                chunk_valid_q <= 1'b0;
              end
            end
          end
        end

        //---------------------------------------------------------------------
        S_STATUS: begin
          if (status_room) begin
            status_beat_q <= 1'b1;
            if (status_beat_q) begin
              state_q       <= S_HDR;
              status_beat_q <= 1'b0;
            end
          end
        end

        //---------------------------------------------------------------------
        default: begin
          state_q <= S_HDR;
        end
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (ARRAY_N < 2) begin
      $fatal(1, "cnn_accel_ctrl: ARRAY_N must be >= 2 (got %0d)", ARRAY_N);
    end
    if (ACC_DEPTH < 1) begin
      $fatal(1, "cnn_accel_ctrl: ACC_DEPTH must be >= 1 (got %0d)", ACC_DEPTH);
    end
    if (ACC_DEPTH > 65535) begin
      $fatal(1, {"cnn_accel_ctrl: ACC_DEPTH (%0d) exceeds what the 16-bit ",
                 "header count field can express"}, ACC_DEPTH);
    end
  end

  // The array's own assertion forbids this; catching it on the driving side
  // names the cause rather than the symptom.
  property p_commit_when_drained;
    @(posedge clk) disable iff (!rst_n) (w_commit |-> !array_busy);
  endproperty
  a_commit_when_drained : assert property (p_commit_when_drained)
    else $error("cnn_accel_ctrl: weight commit issued while the array is busy");

  property p_no_weight_during_compute;
    @(posedge clk) disable iff (!rst_n) (w_beat |-> !a_beat);
  endproperty
  a_no_weight_during_compute : assert property (p_no_weight_during_compute)
    else $error("cnn_accel_ctrl: weight row and activation vector in one cycle");

  property p_params_when_drained;
    @(posedge clk) disable iff (!rst_n) (p_beat |-> pipe_empty);
  endproperty
  a_params_when_drained : assert property (p_params_when_drained)
    else $error({"cnn_accel_ctrl: requantisation parameters written while ",
                 "results are still in flight"});

  property p_first_vector_when_drained;
    @(posedge clk) disable iff (!rst_n)
      ((a_beat && (beat_q == '0)) |-> pipe_empty);
  endproperty
  a_first_vector_when_drained : assert property (p_first_vector_when_drained)
    else $error({"cnn_accel_ctrl: a COMPUTE frame started before the previous ",
                 "one retired"});
`endif

endmodule

`default_nettype wire
