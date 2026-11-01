//=============================================================================
// Testbench   : tb_cnn_accel
// Description : Self-checking SystemVerilog testbench for cnn_accel.
//
// Drives the accelerator the way its host driver does - weight frame,
// parameter frame, compute frame - and checks the int8 results against a
// model of the whole datapath: the matrix product, the accumulation across
// tiles, and the requantisation.
//
// It also sends a truncated weight frame, because an accelerator with no
// register interface has to survive a malformed one. A parser that
// desynchronised would make every subsequent job wrong, and the failure would
// present as an arithmetic bug rather than a framing one.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_cnn_accel;

  localparam int unsigned ARRAY_N        = 8;
  localparam int unsigned DATA_WIDTH     = 8;
  localparam int unsigned ACC_WIDTH      = 32;
  localparam int unsigned MULT_WIDTH     = 24;
  localparam int unsigned SHIFT_WIDTH    = 6;
  localparam int unsigned ACC_DEPTH      = 32;
  localparam int unsigned OUT_FIFO_DEPTH = 32;

  localparam int unsigned STREAM_WIDTH = ARRAY_N * DATA_WIDTH;
  localparam time         CLK_PERIOD   = 4ns;

  localparam logic [7:0] OP_NOP          = 8'h00;
  localparam logic [7:0] OP_LOAD_WEIGHTS = 8'h01;
  localparam logic [7:0] OP_LOAD_PARAMS  = 8'h02;
  localparam logic [7:0] OP_COMPUTE      = 8'h03;

  localparam logic [1:0] FLAG_FIRST = 2'b01;
  localparam logic [1:0] FLAG_LAST  = 2'b10;

  localparam int signed OUT_LOW  = -(2 ** (DATA_WIDTH - 1));
  localparam int signed OUT_HIGH = (2 ** (DATA_WIDTH - 1)) - 1;

  logic                      clk;
  logic                      rst_n;
  logic                      s_axis_tvalid;
  logic                      s_axis_tready;
  logic [STREAM_WIDTH-1:0]   s_axis_tdata;
  logic                      s_axis_tlast;
  logic                      m_axis_tvalid;
  logic                      m_axis_tready;
  logic [STREAM_WIDTH-1:0]   m_axis_tdata;
  logic                      m_axis_tlast;
  logic                      irq;
  logic                      error;
  logic                      busy;

  int unsigned error_count;
  int unsigned check_count;
  int unsigned frame_count;

  // Model state
  logic signed [DATA_WIDTH-1:0] tile   [ARRAY_N][ARRAY_N];
  longint signed                accum  [ACC_DEPTH][ARRAY_N];
  longint signed                bias_m [ARRAY_N];
  longint signed                mult_m [ARRAY_N];
  int unsigned                  shift_m[ARRAY_N];
  longint signed                zero_point_m;
  longint signed                out_min_m;
  longint signed                out_max_m;

  logic [STREAM_WIDTH-1:0] expected [$];

  cnn_accel #(
      .ARRAY_N        (ARRAY_N),
      .DATA_WIDTH     (DATA_WIDTH),
      .ACC_WIDTH      (ACC_WIDTH),
      .MULT_WIDTH     (MULT_WIDTH),
      .SHIFT_WIDTH    (SHIFT_WIDTH),
      .ACC_DEPTH      (ACC_DEPTH),
      .OUT_FIFO_DEPTH (OUT_FIFO_DEPTH)
  ) dut (
      .clk           (clk),
      .rst_n         (rst_n),
      .s_axis_tvalid (s_axis_tvalid),
      .s_axis_tready (s_axis_tready),
      .s_axis_tdata  (s_axis_tdata),
      .s_axis_tlast  (s_axis_tlast),
      .m_axis_tvalid (m_axis_tvalid),
      .m_axis_tready (m_axis_tready),
      .m_axis_tdata  (m_axis_tdata),
      .m_axis_tlast  (m_axis_tlast),
      .irq           (irq),
      .error         (error),
      .busy          (busy)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Requantisation model - the same arithmetic as requant_int8 and the driver.
  //---------------------------------------------------------------------------
  function automatic longint signed requantise(input longint signed acc_v,
                                               input int unsigned channel);
    longint signed product;
    longint signed half;
    longint signed adjust;
    longint signed value;

    product = (acc_v + bias_m[channel]) * mult_m[channel];
    if (shift_m[channel] == 0) begin
      adjust = 0;
    end else begin
      half   = longint'(1) <<< (shift_m[channel] - 1);
      adjust = (product < 0) ? half - 1 : half;
    end

    value = ((product + adjust) >>> shift_m[channel]) + zero_point_m;
    if (value < out_min_m) return out_min_m;
    if (value > out_max_m) return out_max_m;
    return value;
  endfunction

  //---------------------------------------------------------------------------
  // Stream driver
  //---------------------------------------------------------------------------
  task automatic send_beat(input logic [STREAM_WIDTH-1:0] data,
                           input bit last);
    @(negedge clk);
    s_axis_tvalid = 1'b1;
    s_axis_tdata  = data;
    s_axis_tlast  = last;
    do begin
      @(posedge clk);
    end while (s_axis_tready !== 1'b1);
    @(negedge clk);
    s_axis_tvalid = 1'b0;
    s_axis_tlast  = 1'b0;
    s_axis_tdata  = '0;
  endtask

  function automatic logic [STREAM_WIDTH-1:0] make_header(
      input logic [7:0]  opcode,
      input logic [15:0] count,
      input logic [1:0]  flags,
      input logic [7:0]  zero_point,
      input logic [7:0]  low,
      input logic [7:0]  high);
    logic [STREAM_WIDTH-1:0] word;
    word          = '0;
    word[7:0]     = opcode;
    word[9:8]     = flags;
    word[31:16]   = count;
    word[39:32]   = zero_point;
    word[47:40]   = low;
    word[55:48]   = high;
    return word;
  endfunction

  //---------------------------------------------------------------------------
  // Commands
  //---------------------------------------------------------------------------
  task automatic load_weights(input logic signed [DATA_WIDTH-1:0] values [ARRAY_N][ARRAY_N],
                              input int unsigned rows);
    logic [STREAM_WIDTH-1:0] beat;

    send_beat(make_header(OP_LOAD_WEIGHTS, 16'(ARRAY_N), 2'b00, 8'h00,
                          8'(OUT_LOW), 8'(OUT_HIGH)), 1'b0);
    for (int unsigned k = 0; k < rows; k++) begin
      beat = '0;
      for (int unsigned m = 0; m < ARRAY_N; m++) begin
        beat[m*DATA_WIDTH +: DATA_WIDTH] = values[k][m];
      end
      send_beat(beat, (k == rows - 1));
    end
    if (rows == ARRAY_N) begin
      tile = values;
    end
  endtask

  task automatic load_params(input longint signed biases [ARRAY_N],
                             input longint signed mults  [ARRAY_N],
                             input int unsigned   shifts [ARRAY_N],
                             input longint signed zero_point,
                             input longint signed low,
                             input longint signed high);
    logic [STREAM_WIDTH-1:0] beat;

    send_beat(make_header(OP_LOAD_PARAMS, 16'(ARRAY_N), 2'b00,
                          8'(zero_point), 8'(low), 8'(high)), 1'b0);
    for (int unsigned m = 0; m < ARRAY_N; m++) begin
      beat                                          = '0;
      beat[ACC_WIDTH-1:0]                           = ACC_WIDTH'(biases[m]);
      beat[ACC_WIDTH +: MULT_WIDTH]                 = MULT_WIDTH'(mults[m]);
      beat[ACC_WIDTH+MULT_WIDTH +: SHIFT_WIDTH]     = SHIFT_WIDTH'(shifts[m]);
      send_beat(beat, (m == ARRAY_N - 1));
    end

    bias_m       = biases;
    mult_m       = mults;
    shift_m      = shifts;
    zero_point_m = zero_point;
    out_min_m    = low;
    out_max_m    = high;
  endtask

  // Sends a compute frame and pushes the expected results when it emits.
  task automatic compute(input logic signed [DATA_WIDTH-1:0] batch [ACC_DEPTH][ARRAY_N],
                         input int unsigned length,
                         input bit first,
                         input bit last);
    logic [STREAM_WIDTH-1:0] beat;
    logic [1:0]              flags;
    longint signed           total;

    // The model runs before the frame is sent, not after. A batch longer than
    // the pipeline is deep starts producing results while its later beats are
    // still going in, so an expectation queue filled afterwards would be empty
    // when the first result arrives.
    for (int unsigned v = 0; v < length; v++) begin
      for (int unsigned m = 0; m < ARRAY_N; m++) begin
        total = 0;
        for (int unsigned k = 0; k < ARRAY_N; k++) begin
          total = total + longint'(tile[k][m]) * longint'(batch[v][k]);
        end
        accum[v][m] = first ? total : accum[v][m] + total;
      end
    end

    if (last) begin
      for (int unsigned v = 0; v < length; v++) begin
        beat = '0;
        for (int unsigned m = 0; m < ARRAY_N; m++) begin
          beat[m*DATA_WIDTH +: DATA_WIDTH] =
              DATA_WIDTH'(requantise(accum[v][m], m));
        end
        expected.push_back(beat);
      end
    end

    flags = (first ? FLAG_FIRST : 2'b00) | (last ? FLAG_LAST : 2'b00);
    send_beat(make_header(OP_COMPUTE, 16'(length), flags, 8'h00,
                          8'(OUT_LOW), 8'(OUT_HIGH)), 1'b0);

    for (int unsigned v = 0; v < length; v++) begin
      beat = '0;
      for (int unsigned k = 0; k < ARRAY_N; k++) begin
        beat[k*DATA_WIDTH +: DATA_WIDTH] = batch[v][k];
      end
      send_beat(beat, (v == length - 1));
    end
  endtask

  //---------------------------------------------------------------------------
  // Result monitor
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n && m_axis_tvalid && m_axis_tready) begin
      if (expected.size() == 0) begin
        error_count++;
        $error("an unexpected result beat 0x%0h arrived at %0t",
               m_axis_tdata, $time);
      end else begin
        automatic logic [STREAM_WIDTH-1:0] want = expected.pop_front();
        check_count++;
        if (m_axis_tdata !== want) begin
          error_count++;
          for (int unsigned m = 0; m < ARRAY_N; m++) begin
            if (m_axis_tdata[m*DATA_WIDTH +: DATA_WIDTH] !==
                want[m*DATA_WIDTH +: DATA_WIDTH]) begin
              $error("beat %0d channel %0d: expected %0d, got %0d at %0t",
                     check_count, m,
                     $signed(want[m*DATA_WIDTH +: DATA_WIDTH]),
                     $signed(m_axis_tdata[m*DATA_WIDTH +: DATA_WIDTH]),
                     $time);
            end
          end
        end
      end
      if (m_axis_tlast) begin
        frame_count++;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Stimulus
  //---------------------------------------------------------------------------
  initial begin
    logic signed [DATA_WIDTH-1:0] values [ARRAY_N][ARRAY_N];
    logic signed [DATA_WIDTH-1:0] batch  [ACC_DEPTH][ARRAY_N];
    longint signed                biases [ARRAY_N];
    longint signed                mults  [ARRAY_N];
    int unsigned                  shifts [ARRAY_N];

    error_count   = 0;
    check_count   = 0;
    frame_count   = 0;
    rst_n         = 1'b0;
    s_axis_tvalid = 1'b0;
    s_axis_tdata  = '0;
    s_axis_tlast  = 1'b0;
    m_axis_tready = 1'b1;
    zero_point_m  = 0;
    out_min_m     = OUT_LOW;
    out_max_m     = OUT_HIGH;
    for (int unsigned m = 0; m < ARRAY_N; m++) begin
      bias_m[m]  = 0;
      mult_m[m]  = 1;
      shift_m[m] = 0;
      for (int unsigned k = 0; k < ARRAY_N; k++) begin
        tile[k][m] = '0;
      end
    end

    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    #1;

    // --- reset state ---------------------------------------------------------
    if (s_axis_tready !== 1'b1 || m_axis_tvalid !== 1'b0 ||
        busy !== 1'b0 || error !== 1'b0) begin
      error_count++;
      $error("reset state wrong: tready=%0b tvalid=%0b busy=%0b error=%0b",
             s_axis_tready, m_axis_tvalid, busy, error);
    end

    // --- an identity layer must return its input -----------------------------
    for (int unsigned k = 0; k < ARRAY_N; k++) begin
      for (int unsigned m = 0; m < ARRAY_N; m++) begin
        values[k][m] = (k == m) ? DATA_WIDTH'(1) : DATA_WIDTH'(0);
      end
    end
    for (int unsigned m = 0; m < ARRAY_N; m++) begin
      biases[m] = 0;
      mults[m]  = 1;
      shifts[m] = 0;
    end

    load_weights(values, ARRAY_N);
    load_params(biases, mults, shifts, 0, OUT_LOW, OUT_HIGH);

    for (int unsigned v = 0; v < 8; v++) begin
      for (int unsigned k = 0; k < ARRAY_N; k++) begin
        batch[v][k] = DATA_WIDTH'($urandom_range(0, 60)) - DATA_WIDTH'(30);
      end
    end
    compute(batch, 8, 1'b1, 1'b1);
    wait (expected.size() == 0);
    repeat (8) @(posedge clk);

    // --- a random tile with a per-channel scale ------------------------------
    for (int unsigned k = 0; k < ARRAY_N; k++) begin
      for (int unsigned m = 0; m < ARRAY_N; m++) begin
        values[k][m] = DATA_WIDTH'($urandom());
      end
    end
    for (int unsigned m = 0; m < ARRAY_N; m++) begin
      biases[m] = longint'($urandom_range(0, 2000)) - 1000;
      mults[m]  = longint'($urandom_range(1, (2 ** MULT_WIDTH) - 1));
      shifts[m] = $urandom_range(MULT_WIDTH - 2, MULT_WIDTH + 6);
    end

    load_weights(values, ARRAY_N);
    load_params(biases, mults, shifts, 3, OUT_LOW, OUT_HIGH);

    for (int unsigned v = 0; v < ACC_DEPTH; v++) begin
      for (int unsigned k = 0; k < ARRAY_N; k++) begin
        batch[v][k] = DATA_WIDTH'($urandom());
      end
    end
    compute(batch, ACC_DEPTH, 1'b1, 1'b1);
    wait (expected.size() == 0);
    repeat (8) @(posedge clk);

    // --- a reduction split over three tiles ----------------------------------
    for (int unsigned t = 0; t < 3; t++) begin
      for (int unsigned k = 0; k < ARRAY_N; k++) begin
        for (int unsigned m = 0; m < ARRAY_N; m++) begin
          values[k][m] = DATA_WIDTH'($urandom());
        end
      end
      load_weights(values, ARRAY_N);
      for (int unsigned v = 0; v < 12; v++) begin
        for (int unsigned k = 0; k < ARRAY_N; k++) begin
          batch[v][k] = DATA_WIDTH'($urandom());
        end
      end
      compute(batch, 12, (t == 0), (t == 2));
    end
    wait (expected.size() == 0);
    repeat (8) @(posedge clk);

    if (frame_count != 3) begin
      error_count++;
      $error("expected 3 result frames, saw %0d", frame_count);
    end

    // --- a truncated weight frame must be refused, not half loaded -----------
    for (int unsigned k = 0; k < ARRAY_N; k++) begin
      for (int unsigned m = 0; m < ARRAY_N; m++) begin
        values[k][m] = (k == m) ? DATA_WIDTH'(1) : DATA_WIDTH'(0);
      end
    end
    for (int unsigned m = 0; m < ARRAY_N; m++) begin
      biases[m] = 0;
      mults[m]  = 1;
      shifts[m] = 0;
    end
    load_weights(values, ARRAY_N);
    load_params(biases, mults, shifts, 0, OUT_LOW, OUT_HIGH);

    for (int unsigned k = 0; k < ARRAY_N; k++) begin
      for (int unsigned m = 0; m < ARRAY_N; m++) begin
        values[k][m] = DATA_WIDTH'(9);
      end
    end
    load_weights(values, ARRAY_N - 2);      // ends two rows early

    #1;
    if (error !== 1'b1) begin
      error_count++;
      $error("a truncated weight frame did not raise the error flag");
    end

    // The identity tile must still be the published one.
    for (int unsigned v = 0; v < 6; v++) begin
      for (int unsigned k = 0; k < ARRAY_N; k++) begin
        batch[v][k] = DATA_WIDTH'($urandom_range(0, 40)) - DATA_WIDTH'(20);
      end
    end
    compute(batch, 6, 1'b1, 1'b1);
    wait (expected.size() == 0);
    repeat (8) @(posedge clk);

    // A NOP acknowledges the error.
    send_beat(make_header(OP_NOP, 16'd0, 2'b00, 8'h00, 8'(OUT_LOW),
                          8'(OUT_HIGH)), 1'b1);
    repeat (4) @(posedge clk);
    #1;
    if (error !== 1'b0) begin
      error_count++;
      $error("NOP did not clear the sticky error");
    end

    repeat (16) @(posedge clk);
    #1;
    if (busy !== 1'b0) begin
      error_count++;
      $error("busy is still asserted with nothing outstanding");
    end

    // --- verdict -------------------------------------------------------------
    if (expected.size() != 0) begin
      error_count++;
      $error("%0d expected result beat(s) never arrived", expected.size());
    end
    if (check_count == 0) begin
      error_count++;
      $error("no results were checked at all");
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_cnn_accel (%0dx%0d, %0d beats, %0d frames)",
               ARRAY_N, ARRAY_N, check_count, frame_count);
      $finish;
    end else begin
      $display("TEST FAILED: tb_cnn_accel, %0d error(s)", error_count);
      $fatal(1, "tb_cnn_accel failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 500000);
    $fatal(1, "tb_cnn_accel: global timeout");
  end

endmodule

`default_nettype wire
