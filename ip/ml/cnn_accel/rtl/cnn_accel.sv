//=============================================================================
// Module      : cnn_accel
// Category    : ml
// Description : Quantised int8 CNN inference accelerator: a systolic
//               matrix-multiply array with an output accumulator buffer and
//               per-channel requantisation, driven entirely over AXI4-Stream.
//
// The block computes tiles of the matrix product a convolution becomes once it
// has been lowered to a GEMM. A host - on the reference platform a bare-metal
// Cortex-A53 driving an AXI DMA - streams a weight tile, the requantisation
// parameters and a batch of activation vectors, and receives a batch of int8
// results.
//
// NO REGISTER INTERFACE
//   Every command arrives as a frame on the data stream: a header beat, then
//   its payload, delimited by TLAST. That is a deliberate architectural
//   choice rather than a shortcut. It means the accelerator needs no AXI4-Lite
//   port, and more importantly it means a whole layer - dozens of weight tiles
//   and compute batches - can be queued as one scatter-gather descriptor chain
//   and run to completion with no processor involvement at all. A design
//   driven through control registers has to interrupt the processor between
//   tiles, and at 250 MHz the tiles are short enough that the interrupt
//   latency would dominate.
//
//   `cnn_accel_ctrl` owns the frame format; it is documented there.
//
// DATAPATH
//
//   s_axis --> [ ctrl ] --+--> weight rows -----> systolic_array
//                         |                            |
//                         +--> activation vectors -----+
//                         |                            v
//                         |                    ACC_WIDTH column sums
//                         |                            |
//                         |                            v
//                         |                  +-------------------+
//                         |                  | accumulator RAM   |
//                         |                  | read-add-write    |
//                         |                  +---------+---------+
//                         |                            |
//                         +--> requant parameters -->  v
//                                             ARRAY_N x requant_int8
//                                                      |
//                                                      v
//                                            fifo_sync --> m_axis
//
// THE ACCUMULATOR BUFFER IS WHAT MAKES IT A CNN ACCELERATOR
//   The array reduces over ARRAY_N terms. A real convolution layer reduces
//   over `kernel_h * kernel_w * input_channels`, which is routinely hundreds.
//   Without somewhere to keep partial sums, the host would have to add the
//   tiles together itself, in int32, on the processor - and that is
//   ARRAY_N times less arithmetic than the accelerator is doing but on a
//   scalar core, so it would become the bottleneck almost immediately.
//
//   So results land in a buffer indexed by position within the batch, and each
//   tile adds into it. The COMPUTE header carries two flags: `first` clears
//   the buffer instead of adding, `last` requantises and emits. A layer whose
//   reduction fits in one tile sets both.
//
//   The buffer bounds the batch length to ACC_DEPTH vectors, which is what the
//   host tiles the output positions against.
//
// FLOW CONTROL BY CREDIT
//   The array and the requantiser are fixed-latency pipelines that cannot be
//   stalled. Rather than building a stall network through 256 elements, the
//   block refuses to admit an activation unless the output buffer already has
//   room for the result that will arrive TOTAL_LATENCY cycles later. The
//   accounting is one counter: vectors admitted, minus vectors that have
//   reached the far end.
//
//   That is also why the output FIFO must be deeper than the pipeline - an
//   elaboration check enforces it. A shallower one would deadlock: no credit
//   to admit work, and no work in flight to release the credit.
//
// Parameters
//   ARRAY_N         Array dimension. The stream is ARRAY_N*DATA_WIDTH wide.
//   DATA_WIDTH      Activation, weight and output width. 8 for int8.
//   ACC_WIDTH       Accumulator width.
//   MULT_WIDTH      Requantisation multiplier width.
//   SHIFT_WIDTH     Requantisation shift width.
//   ACC_DEPTH       Accumulator buffer depth; the largest COMPUTE batch.
//   OUT_FIFO_DEPTH  Output buffer depth. Must exceed the pipeline latency.
//
// Latency     : 2*ARRAY_N + 4 cycles, activation vector to result vector
// Throughput  : one activation vector per cycle, sustained
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module cnn_accel #(
    parameter int unsigned ARRAY_N        = 16,
    parameter int unsigned DATA_WIDTH     = 8,
    parameter int unsigned ACC_WIDTH      = 32,
    parameter int unsigned MULT_WIDTH     = 24,
    parameter int unsigned SHIFT_WIDTH    = 6,
    parameter int unsigned ACC_DEPTH      = 256,
    parameter int unsigned OUT_FIFO_DEPTH = 64
) (
    input  wire                            clk,
    input  wire                            rst_n,

    // AXI4-Stream sink: commands and data
    input  wire                            s_axis_tvalid,
    output logic                           s_axis_tready,
    input  wire  [ARRAY_N*DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire                            s_axis_tlast,

    // AXI4-Stream source: results and status replies
    output logic                           m_axis_tvalid,
    input  wire                            m_axis_tready,
    output logic [ARRAY_N*DATA_WIDTH-1:0]  m_axis_tdata,
    output logic                           m_axis_tlast,

    // Sideband
    output logic                           irq,     // an output frame completed
    output logic                           error,   // sticky protocol error
    output logic                           busy
);

  localparam int unsigned STREAM_WIDTH  = ARRAY_N * DATA_WIDTH;
  localparam int unsigned ADDR_WIDTH    = $clog2(ACC_DEPTH);
  localparam int unsigned COUNT_WIDTH   = 16;

  // systolic_array is ARRAY_N + ARRAY_N - 1; the accumulator read-add-write
  // adds two; requant_int8 adds three.
  localparam int unsigned ARRAY_LATENCY = 2 * ARRAY_N - 1;
  localparam int unsigned TOTAL_LATENCY = ARRAY_LATENCY + 5;

  localparam int unsigned FLIGHT_WIDTH  = $clog2(OUT_FIFO_DEPTH + 1);
  localparam int unsigned LEVEL_WIDTH   = $clog2(OUT_FIFO_DEPTH + 1);

  // Requantisation parameter beat layout, packed from the bottom so it stays
  // inside a 64-bit field for every legal configuration.
  localparam int unsigned BIAS_LSB  = 0;
  localparam int unsigned MULT_LSB  = ACC_WIDTH;
  localparam int unsigned SHIFT_LSB = ACC_WIDTH + MULT_WIDTH;

  localparam logic [7:0] VERSION = 8'h01;

  //---------------------------------------------------------------------------
  // Control
  //---------------------------------------------------------------------------
  logic                        ctrl_w_beat;
  logic                        ctrl_w_commit;
  logic                        ctrl_p_beat;
  logic [$clog2(ARRAY_N)-1:0]  ctrl_p_index;
  logic                        ctrl_p_header;
  logic                        ctrl_a_beat;
  logic                        ctrl_a_frame_first;
  logic                        ctrl_a_frame_end;
  logic                        ctrl_acc_first;
  logic                        ctrl_acc_last;
  logic                        ctrl_status_push;
  logic                        ctrl_status_index;
  logic                        ctrl_frame_active;

  logic                        credit_ok;
  logic                        pipe_empty;
  logic                        array_busy;
  logic                        status_room;

  cnn_accel_ctrl #(
      .ARRAY_N   (ARRAY_N),
      .ACC_DEPTH (ACC_DEPTH)
  ) u_ctrl (
      .clk           (clk),
      .rst_n         (rst_n),
      .s_valid       (s_axis_tvalid),
      .s_ready       (s_axis_tready),
      .s_last        (s_axis_tlast),
      .hdr_opcode    (s_axis_tdata[7:0]),
      .hdr_flags     (s_axis_tdata[9:8]),
      .hdr_count     (s_axis_tdata[31:16]),
      .credit_ok     (credit_ok),
      .pipe_empty    (pipe_empty),
      .array_busy    (array_busy),
      .status_room   (status_room),
      .w_beat        (ctrl_w_beat),
      .w_commit      (ctrl_w_commit),
      .p_beat        (ctrl_p_beat),
      .p_index       (ctrl_p_index),
      .p_header      (ctrl_p_header),
      .a_beat        (ctrl_a_beat),
      .a_frame_first (ctrl_a_frame_first),
      .a_frame_end   (ctrl_a_frame_end),
      .acc_first     (ctrl_acc_first),
      .acc_last      (ctrl_acc_last),
      .status_push   (ctrl_status_push),
      .status_index  (ctrl_status_index),
      .frame_active  (ctrl_frame_active),
      .error_flag    (error)
  );

  //---------------------------------------------------------------------------
  // Requantisation parameters.
  //
  // One set per output channel, written by a LOAD_PARAMS frame. The control
  // block guarantees the pipeline is empty while they are written, so there is
  // no shadow copy: unlike the weights, these change once per output-channel
  // tile rather than once per input-channel tile, so the load is rare enough
  // that stalling for it costs nothing measurable.
  //---------------------------------------------------------------------------
  logic [ACC_WIDTH-1:0]   bias_q  [ARRAY_N];
  logic [MULT_WIDTH-1:0]  mult_q  [ARRAY_N];
  logic [SHIFT_WIDTH-1:0] shift_q [ARRAY_N];

  logic [DATA_WIDTH-1:0]  out_zero_point_q;
  logic [DATA_WIDTH-1:0]  out_min_q;
  logic [DATA_WIDTH-1:0]  out_max_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int unsigned m = 0; m < ARRAY_N; m++) begin
        bias_q[m]  <= '0;
        mult_q[m]  <= '0;
        shift_q[m] <= '0;
      end
      out_zero_point_q <= '0;
      out_min_q        <= {1'b1, {(DATA_WIDTH-1){1'b0}}};   // most negative
      out_max_q        <= {1'b0, {(DATA_WIDTH-1){1'b1}}};   // most positive
    end else begin
      if (ctrl_p_header) begin
        out_zero_point_q <= s_axis_tdata[32 +: DATA_WIDTH];
        out_min_q        <= s_axis_tdata[40 +: DATA_WIDTH];
        out_max_q        <= s_axis_tdata[48 +: DATA_WIDTH];
      end
      if (ctrl_p_beat) begin
        bias_q[ctrl_p_index]  <= s_axis_tdata[BIAS_LSB  +: ACC_WIDTH];
        mult_q[ctrl_p_index]  <= s_axis_tdata[MULT_LSB  +: MULT_WIDTH];
        shift_q[ctrl_p_index] <= s_axis_tdata[SHIFT_LSB +: SHIFT_WIDTH];
      end
    end
  end

  //---------------------------------------------------------------------------
  // The array
  //---------------------------------------------------------------------------
  logic                          array_res_valid;
  logic [ARRAY_N*ACC_WIDTH-1:0]  array_res_vector;

  systolic_array #(
      .ROWS       (ARRAY_N),
      .COLS       (ARRAY_N),
      .DATA_WIDTH (DATA_WIDTH),
      .ACC_WIDTH  (ACC_WIDTH)
  ) u_array (
      .clk        (clk),
      .rst_n      (rst_n),
      .w_valid    (ctrl_w_beat),
      .w_row      (s_axis_tdata),
      .w_commit   (ctrl_w_commit),
      .a_valid    (ctrl_a_beat),
      .a_vector   (s_axis_tdata),
      .res_valid  (array_res_valid),
      .res_vector (array_res_vector),
      .busy       (array_busy)
  );

  //---------------------------------------------------------------------------
  // Per-frame bookkeeping.
  //
  // Owned here rather than in the control block because it has to stay valid
  // while a frame's results drain, which outlasts the frame on the input side.
  // The first admitted vector - not the header - is what starts a new frame's
  // accounting, precisely so that a header accepted during the previous
  // frame's drain cannot disturb it.
  //---------------------------------------------------------------------------
  logic [COUNT_WIDTH-1:0] admitted_q;
  logic                   input_done_q;
  logic                   acc_first_q;
  logic                   acc_last_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      admitted_q   <= '0;
      input_done_q <= 1'b0;
      acc_first_q  <= 1'b0;
      acc_last_q   <= 1'b0;
    end else begin
      if (ctrl_a_frame_first) begin
        admitted_q   <= COUNT_WIDTH'(1);
        input_done_q <= 1'b0;
        acc_first_q  <= ctrl_acc_first;
        acc_last_q   <= ctrl_acc_last;
      end else if (ctrl_a_beat) begin
        admitted_q <= admitted_q + COUNT_WIDTH'(1);
      end

      if (ctrl_a_frame_end) begin
        input_done_q <= 1'b1;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Accumulator buffer: read, add, write back.
  //
  // Results leave the array in the order their vectors were admitted, so the
  // buffer address is simply a counter of results. The read is issued in the
  // cycle the result appears and consumed in the next, which is also when the
  // sum is written back - so the read and the write are always one address
  // apart and never collide. Addresses restart at zero only at the first
  // admitted vector of a frame, and the control block guarantees the pipeline
  // is empty at that point.
  //---------------------------------------------------------------------------
  logic [ADDR_WIDTH-1:0]         acc_addr_q;
  logic                          acc_valid_q;
  logic [ARRAY_N*ACC_WIDTH-1:0]  acc_data_q;
  logic [ADDR_WIDTH-1:0]         acc_wr_addr_q;
  logic                          acc_last_beat_q;

  logic [ARRAY_N*ACC_WIDTH-1:0]  acc_rdata;
  logic [ARRAY_N*ACC_WIDTH-1:0]  acc_sum;

  // The result being written back is the one whose index is acc_wr_addr_q; it
  // closes the frame when the input side has finished and it is the last
  // vector that was admitted.
  logic result_is_last;
  assign result_is_last = input_done_q &&
                          (COUNT_WIDTH'(acc_addr_q) + COUNT_WIDTH'(1) ==
                           admitted_q);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      acc_addr_q      <= '0;
      acc_valid_q     <= 1'b0;
      acc_data_q      <= '0;
      acc_wr_addr_q   <= '0;
      acc_last_beat_q <= 1'b0;
    end else begin
      if (ctrl_a_frame_first) begin
        acc_addr_q <= '0;
      end else if (array_res_valid) begin
        acc_addr_q <= acc_addr_q + ADDR_WIDTH'(1);
      end

      acc_valid_q     <= array_res_valid;
      acc_data_q      <= array_res_vector;
      acc_wr_addr_q   <= acc_addr_q;
      acc_last_beat_q <= array_res_valid && result_is_last;
    end
  end

  ram_sdp #(
      .DATA_WIDTH  (ARRAY_N * ACC_WIDTH),
      .DEPTH       (ACC_DEPTH),
      .BYTE_ENABLE (0),
      .OUTPUT_REG  (0)
  ) u_accumulator (
      .wr_clk  (clk),
      .wr_en   (acc_valid_q),
      .wr_be   ('1),
      .wr_addr (acc_wr_addr_q),
      .wr_data (acc_sum),
      .rd_clk  (clk),
      .rd_en   (array_res_valid),
      .rd_addr (acc_addr_q),
      .rd_data (acc_rdata)
  );

  for (genvar m = 0; m < int'(ARRAY_N); m++) begin : g_accumulate
    // A tile flagged `first` starts the sum rather than adding to whatever the
    // buffer happens to hold, which is what makes the buffer need no clearing
    // pass between chunks.
    assign acc_sum[m*ACC_WIDTH +: ACC_WIDTH] =
        acc_data_q[m*ACC_WIDTH +: ACC_WIDTH] +
        (acc_first_q ? {ACC_WIDTH{1'b0}} : acc_rdata[m*ACC_WIDTH +: ACC_WIDTH]);
  end

  //---------------------------------------------------------------------------
  // Requantisation, one instance per output channel.
  //
  // Fed on every result, including the tiles that will not be emitted, so that
  // the pipeline's exit strobe is uniform: `pipe_empty` and the credit
  // accounting both key off it, and a stage that sometimes runs and sometimes
  // does not would make both of them special cases.
  //---------------------------------------------------------------------------
  logic [ARRAY_N-1:0]    rq_out_valid;
  logic [ARRAY_N-1:0]    rq_saturated;
  logic [STREAM_WIDTH-1:0] rq_out_data;

  for (genvar m = 0; m < int'(ARRAY_N); m++) begin : g_requant
    requant_int8 #(
        .ACC_WIDTH   (ACC_WIDTH),
        .MULT_WIDTH  (MULT_WIDTH),
        .SHIFT_WIDTH (SHIFT_WIDTH),
        .OUT_WIDTH   (DATA_WIDTH)
    ) u_requant (
        .clk            (clk),
        .rst_n          (rst_n),
        .in_valid       (acc_valid_q),
        .acc            (acc_sum[m*ACC_WIDTH +: ACC_WIDTH]),
        .bias           (bias_q[m]),
        .mult           (mult_q[m]),
        .shift          (shift_q[m]),
        .out_zero_point (out_zero_point_q),
        .out_min        (out_min_q),
        .out_max        (out_max_q),
        .out_valid      (rq_out_valid[m]),
        .out_data       (rq_out_data[m*DATA_WIDTH +: DATA_WIDTH]),
        .saturated      (rq_saturated[m])
    );
  end

  //---------------------------------------------------------------------------
  // The end-of-frame tag travels alongside the data through the requantiser,
  // which is a fixed three-cycle pipeline.
  //---------------------------------------------------------------------------
  localparam int unsigned REQUANT_LATENCY = 3;

  logic [REQUANT_LATENCY-1:0] last_pipe_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      last_pipe_q <= '0;
    end else begin
      last_pipe_q <= {last_pipe_q[REQUANT_LATENCY-2:0], acc_last_beat_q};
    end
  end

  logic result_valid;
  logic result_last;

  assign result_valid = rq_out_valid[0];
  assign result_last  = last_pipe_q[REQUANT_LATENCY-1];

  //---------------------------------------------------------------------------
  // Sticky saturation report.
  //
  // Under a fused ReLU saturation is the normal case, so this is information
  // rather than an error - but on a layer with no fused activation a run of
  // saturated results means the scales are wrong, and finding that out from a
  // status read is very much cheaper than finding it out from the accuracy.
  //---------------------------------------------------------------------------
  logic saturation_seen_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      saturation_seen_q <= 1'b0;
    end else if (result_valid && (rq_saturated != '0)) begin
      saturation_seen_q <= 1'b1;
    end
  end

  //---------------------------------------------------------------------------
  // Counters, reported by a STATUS frame.
  //---------------------------------------------------------------------------
  logic [31:0] job_count_q;
  logic [31:0] vector_count_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      job_count_q    <= '0;
      vector_count_q <= '0;
    end else begin
      if (ctrl_a_beat) begin
        vector_count_q <= vector_count_q + 32'd1;
      end
      if (ctrl_a_frame_end && ctrl_acc_last) begin
        job_count_q <= job_count_q + 32'd1;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Output buffer.
  //
  // Carries the TLAST bit alongside the payload so the framing of the reply is
  // decided where the data is produced rather than being reconstructed at the
  // interface.
  //---------------------------------------------------------------------------
  logic [STREAM_WIDTH-1:0] status_word;

  // Beat 0 reports the geometry, which is what lets a host detect that it is
  // talking to a different build from the one it was compiled against - a
  // mismatch that otherwise shows up only as wrong numbers. The buffer depths
  // are there for the same reason: a driver that batches more vectors than the
  // accumulator holds gets an error frame rather than silence.
  //
  //   [ 7: 0] version      [39:32] flags: error, saturated, busy
  //   [15: 8] ARRAY_N      [55:40] ACC_DEPTH
  //   [23:16] DATA_WIDTH   [63:56] OUT_FIFO_DEPTH, saturated to 255
  //   [31:24] ACC_WIDTH
  localparam int unsigned FIFO_DEPTH_REPORTED =
      (OUT_FIFO_DEPTH > 255) ? 255 : OUT_FIFO_DEPTH;

  always_comb begin
    status_word = '0;
    if (ctrl_status_index == 1'b0) begin
      status_word[7:0]   = VERSION;
      status_word[15:8]  = 8'(ARRAY_N);
      status_word[23:16] = 8'(DATA_WIDTH);
      status_word[31:24] = 8'(ACC_WIDTH);
      status_word[32]    = error;
      status_word[33]    = saturation_seen_q;
      status_word[34]    = busy;
      status_word[55:40] = 16'(ACC_DEPTH);
      status_word[63:56] = 8'(FIFO_DEPTH_REPORTED);
    end else begin
      status_word[31:0]  = job_count_q;
      status_word[63:32] = vector_count_q;
    end
  end

  logic                    out_push;
  logic [STREAM_WIDTH:0]   out_word;
  logic                    out_ready;

  assign out_push = (result_valid && acc_last_q) || ctrl_status_push;
  assign out_word = ctrl_status_push ? {ctrl_status_index, status_word}
                                     : {result_last, rq_out_data};

  logic [LEVEL_WIDTH-1:0] fifo_level;
  logic                   fifo_full;
  logic                   fifo_empty;
  logic                   fifo_almost_full;
  logic                   fifo_almost_empty;

  fifo_sync #(
      .DATA_WIDTH (STREAM_WIDTH + 1),
      .DEPTH      (OUT_FIFO_DEPTH)
  ) u_out_fifo (
      .clk          (clk),
      .rst_n        (rst_n),
      .s_valid      (out_push),
      .s_ready      (out_ready),
      .s_data       (out_word),
      .m_valid      (m_axis_tvalid),
      .m_ready      (m_axis_tready),
      .m_data       ({m_axis_tlast, m_axis_tdata}),
      .level        (fifo_level),
      .full         (fifo_full),
      .empty        (fifo_empty),
      .almost_full  (fifo_almost_full),
      .almost_empty (fifo_almost_empty)
  );

  //---------------------------------------------------------------------------
  // Credit accounting.
  //
  // `inflight_q` is the number of vectors between admission and the far end of
  // the requantiser. Admitting one more is only safe if the output buffer
  // could take every one of them plus the new one, because none of them can be
  // stalled once they are inside.
  //---------------------------------------------------------------------------
  logic [FLIGHT_WIDTH-1:0] inflight_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      inflight_q <= '0;
    end else begin
      unique case ({ctrl_a_beat, result_valid})
        2'b10:   inflight_q <= inflight_q + FLIGHT_WIDTH'(1);
        2'b01:   inflight_q <= inflight_q - FLIGHT_WIDTH'(1);
        default: inflight_q <= inflight_q;
      endcase
    end
  end

  assign pipe_empty  = (inflight_q == '0);
  assign credit_ok   = (FLIGHT_WIDTH'(fifo_level) + inflight_q) <
                       FLIGHT_WIDTH'(OUT_FIFO_DEPTH);
  assign status_room = pipe_empty &&
                       (fifo_level <= LEVEL_WIDTH'(OUT_FIFO_DEPTH - 2));

  assign busy = ctrl_frame_active || !pipe_empty || !fifo_empty;

  //---------------------------------------------------------------------------
  // Interrupt: one pulse per completed output frame, at the moment the last
  // beat is taken by the consumer rather than when it was produced, so a host
  // that woke on it can read the whole result without a further check.
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      irq <= 1'b0;
    end else begin
      irq <= m_axis_tvalid && m_axis_tready && m_axis_tlast;
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (ARRAY_N < 8) begin
      $fatal(1, {"cnn_accel: ARRAY_N must be >= 8 (got %0d); the command ",
                 "header and the requantisation parameter beat need a stream ",
                 "at least 64 bits wide"}, ARRAY_N);
    end
    if (DATA_WIDTH != 8) begin
      $fatal(1, {"cnn_accel: DATA_WIDTH must be 8 (got %0d); the header field ",
                 "layout places the clamp values on byte boundaries"},
             DATA_WIDTH);
    end
    if (SHIFT_LSB + SHIFT_WIDTH > STREAM_WIDTH) begin
      $fatal(1, {"cnn_accel: a requantisation parameter beat needs %0d bits ",
                 "but the stream is %0d wide"},
             SHIFT_LSB + SHIFT_WIDTH, STREAM_WIDTH);
    end
    if (OUT_FIFO_DEPTH <= TOTAL_LATENCY) begin
      $fatal(1, {"cnn_accel: OUT_FIFO_DEPTH (%0d) must exceed the pipeline ",
                 "latency (%0d), or the credit scheme deadlocks: no room to ",
                 "admit work, and no work in flight to release the room"},
             OUT_FIFO_DEPTH, TOTAL_LATENCY);
    end
    if (ACC_DEPTH < 2) begin
      $fatal(1, "cnn_accel: ACC_DEPTH must be >= 2 (got %0d)", ACC_DEPTH);
    end
  end

  // Every requantiser sees the same in_valid, so a divergence means one of
  // them has been reset or clocked differently - which would corrupt one lane
  // of every result and nothing else.
  property p_requant_lanes_aligned;
    @(posedge clk) disable iff (!rst_n)
      ((rq_out_valid == '0) || (rq_out_valid == {ARRAY_N{1'b1}}));
  endproperty
  a_requant_lanes_aligned : assert property (p_requant_lanes_aligned)
    else $error("cnn_accel: requantiser lanes disagree on out_valid (%b)",
                rq_out_valid);

  // The credit scheme exists to make this impossible; if it ever fires, a
  // result has been dropped on the floor.
  property p_never_push_when_full;
    @(posedge clk) disable iff (!rst_n) (out_push |-> out_ready);
  endproperty
  a_never_push_when_full : assert property (p_never_push_when_full)
    else $error("cnn_accel: pushed a result into a full output buffer");

  // The accumulator address must stay inside the buffer. The control block
  // rejects a COMPUTE count above ACC_DEPTH, so reaching this means the
  // bookkeeping and the header have diverged.
  property p_accumulator_address_in_range;
    @(posedge clk) disable iff (!rst_n)
      (array_res_valid |-> (COUNT_WIDTH'(acc_addr_q) < COUNT_WIDTH'(ACC_DEPTH)));
  endproperty
  a_accumulator_address_in_range : assert property (p_accumulator_address_in_range)
    else $error("cnn_accel: accumulator address %0d is outside the buffer",
                acc_addr_q);

  // An output frame that never ends would hang the consumer's DMA.
  property p_last_only_with_data;
    @(posedge clk) disable iff (!rst_n) (result_last |-> result_valid);
  endproperty
  a_last_only_with_data : assert property (p_last_only_with_data)
    else $error("cnn_accel: end-of-frame tag without a result to carry it");

  // The occupancy flags are not used by the design; referencing them here
  // keeps them meaningful in a waveform and documents the intended margin.
  property p_almost_flags_consistent;
    @(posedge clk) disable iff (!rst_n)
      ((!fifo_full || fifo_almost_full) && (!fifo_empty || fifo_almost_empty));
  endproperty
  a_almost_flags_consistent : assert property (p_almost_flags_consistent)
    else $error("cnn_accel: output buffer occupancy flags are inconsistent");
`endif

endmodule

`default_nettype wire
