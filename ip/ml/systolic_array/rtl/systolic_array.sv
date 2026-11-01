//=============================================================================
// Module      : systolic_array
// Category    : ml
// Description : ROWS x COLS weight-stationary systolic array of int8
//               multiply-accumulate elements, with the input skew and output
//               deskew that turn it into a plain vector-in, vector-out matrix
//               multiplier.
//
// The array computes one tile of a matrix product. With a weight tile W of
// ROWS by COLS held in the elements, presenting an activation vector `a` of
// ROWS values produces, LATENCY cycles later, the COLS-element vector
//
//     res[m] = sum over k of  W[k][m] * a[k]
//
// One vector may be presented on every cycle. That is the whole point: the
// array is ROWS*COLS multipliers deep, and at one vector per cycle it retires
// ROWS*COLS multiply-accumulates per cycle with no memory bandwidth beyond one
// activation vector in and one result vector out.
//
// SKEW AND DESKEW
//   Inside the array an activation walks east one element per cycle while a
//   partial sum walks south one element per cycle. For the two to meet at the
//   element that owns W[k][m], the activation of row k must be launched k
//   cycles after the activation of row 0. That is what the input skew does:
//   row k is delayed by k cycles.
//
//   The consequence at the far end is that the column sums do not finish
//   together either - column m finishes m cycles after column 0 - so the
//   output deskew delays column m by COLS-1-m cycles to line them up again.
//
//   Both are triangular shift registers, and together they are why the block
//   presents a flat fixed latency of ROWS + COLS - 1 rather than making its
//   user think about wavefronts.
//
//   The deskew registers are ACC_WIDTH wide, which is the one place this
//   partitioning costs area: requantising at the bottom of each column before
//   the deskew would make them eight bits instead of thirty-two. That is a
//   real saving - about 2900 flip-flops at 16 columns - and it is deliberately
//   not taken, because it would put a quantisation policy inside a block whose
//   job is arithmetic, and the saving is under 3% of the flip-flops on the
//   smallest device this array fits.
//
// NO BACK-PRESSURE
//   The array cannot be stalled; there is no ready. Work is admitted or not
//   admitted, and `a_valid` travels with the data so that results emerge
//   tagged. A user that cannot always accept a result must not present a
//   vector - `cnn_accel` does this by refusing an activation unless its output
//   buffer already has room for the result that will arrive LATENCY cycles
//   later.
//
//   Cycles with no work present a zero activation vector, which contributes
//   nothing to any partial sum, so gaps in the input stream are free.
//
// WEIGHT LOADING
//   Weight rows enter at the south edge, one row per `w_valid` beat, and shift
//   northwards. Pushing rows in natural order - row 0 first - therefore leaves
//   row k in row k after ROWS beats. `w_commit` then publishes the whole tile
//   at once from the shadow registers inside the elements, so the next tile
//   can be loaded while the current one is still computing.
//
//   A commit must not land while activations are still inside the array: those
//   vectors would finish their accumulation against a mixture of two tiles.
//   `busy` reports exactly that condition and an assertion checks it.
//
// Parameters
//   ROWS        Reduction depth, and the number of activations per vector.
//   COLS        Output channels, and the number of results per vector.
//   DATA_WIDTH  Activation and weight width, two's complement.
//   ACC_WIDTH   Accumulator width, two's complement. Must be at least
//               2*DATA_WIDTH + $clog2(ROWS) for a full column sum.
//
// Latency     : ROWS + COLS - 1 cycles, activation vector to result vector
// Throughput  : one activation vector per cycle
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module systolic_array #(
    parameter int unsigned ROWS       = 16,
    parameter int unsigned COLS       = 16,
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned ACC_WIDTH  = 32
) (
    input  wire                             clk,
    input  wire                             rst_n,

    // Weight load: one row per beat, entering at the south edge
    input  wire                             w_valid,
    input  wire  [COLS*DATA_WIDTH-1:0]      w_row,
    input  wire                             w_commit,

    // Activation vector, one per cycle
    input  wire                             a_valid,
    input  wire  [ROWS*DATA_WIDTH-1:0]      a_vector,

    // Result vector, LATENCY cycles after the activation vector
    output logic                            res_valid,
    output logic [COLS*ACC_WIDTH-1:0]       res_vector,

    // High while any admitted vector is still inside the pipeline
    output logic                            busy
);

  localparam int unsigned LATENCY = ROWS + COLS - 1;

  //---------------------------------------------------------------------------
  // Input skew: row k is delayed by k cycles.
  //
  // Idle cycles inject zeros rather than holding the previous vector. Either
  // is functionally correct - each result depends only on the vector that was
  // admitted with it - but zeros keep the array quiet and make a waveform
  // readable.
  //---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] a_launch  [ROWS];
  logic [DATA_WIDTH-1:0] a_skewed  [ROWS];

  for (genvar k = 0; k < int'(ROWS); k++) begin : g_launch
    assign a_launch[k] = a_valid ? a_vector[k*DATA_WIDTH +: DATA_WIDTH]
                                 : {DATA_WIDTH{1'b0}};
  end

  for (genvar k = 0; k < int'(ROWS); k++) begin : g_skew
    if (k == 0) begin : g_no_delay
      assign a_skewed[0] = a_launch[0];
    end else begin : g_delay
      logic [DATA_WIDTH-1:0] stage_q [k];

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          for (int unsigned s = 0; s < unsigned'(k); s++) begin
            stage_q[s] <= '0;
          end
        end else begin
          stage_q[0] <= a_launch[k];
          for (int unsigned s = 1; s < unsigned'(k); s++) begin
            stage_q[s] <= stage_q[s-1];
          end
        end
      end

      assign a_skewed[k] = stage_q[k-1];
    end
  end

  //---------------------------------------------------------------------------
  // The element grid.
  //
  //   activations enter from the west and walk east
  //   partial sums enter from the north as zero and walk south
  //   weights enter from the south and shift north
  //---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] a_chain    [ROWS][COLS+1];
  logic [ACC_WIDTH-1:0]  psum_chain [ROWS+1][COLS];
  logic [DATA_WIDTH-1:0] w_chain    [ROWS+1][COLS];

  for (genvar m = 0; m < int'(COLS); m++) begin : g_edges
    assign psum_chain[0][m] = {ACC_WIDTH{1'b0}};
    assign w_chain[ROWS][m] = w_row[m*DATA_WIDTH +: DATA_WIDTH];
  end

  for (genvar k = 0; k < int'(ROWS); k++) begin : g_west_edge
    assign a_chain[k][0] = a_skewed[k];
  end

  for (genvar k = 0; k < int'(ROWS); k++) begin : g_row
    for (genvar m = 0; m < int'(COLS); m++) begin : g_col
      systolic_pe #(
          .DATA_WIDTH (DATA_WIDTH),
          .ACC_WIDTH  (ACC_WIDTH)
      ) u_pe (
          .clk      (clk),
          .rst_n    (rst_n),
          .w_shift  (w_valid),
          .w_commit (w_commit),
          .w_in     (w_chain[k+1][m]),
          .w_out    (w_chain[k][m]),
          .a_in     (a_chain[k][m]),
          .a_out    (a_chain[k][m+1]),
          .psum_in  (psum_chain[k][m]),
          .psum_out (psum_chain[k+1][m])
      );
    end
  end

  //---------------------------------------------------------------------------
  // Output deskew: column m finishes m cycles after column 0, so it is delayed
  // by COLS-1-m to bring the whole vector back into step.
  //---------------------------------------------------------------------------
  for (genvar m = 0; m < int'(COLS); m++) begin : g_deskew
    localparam int unsigned DEPTH = COLS - 1 - m;

    if (DEPTH == 0) begin : g_no_delay
      assign res_vector[m*ACC_WIDTH +: ACC_WIDTH] = psum_chain[ROWS][m];
    end else begin : g_delay
      logic [ACC_WIDTH-1:0] stage_q [DEPTH];

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          for (int unsigned s = 0; s < DEPTH; s++) begin
            stage_q[s] <= '0;
          end
        end else begin
          stage_q[0] <= psum_chain[ROWS][m];
          for (int unsigned s = 1; s < DEPTH; s++) begin
            stage_q[s] <= stage_q[s-1];
          end
        end
      end

      assign res_vector[m*ACC_WIDTH +: ACC_WIDTH] = stage_q[DEPTH-1];
    end
  end

  //---------------------------------------------------------------------------
  // Valid tracking.
  //
  // The delay line is the array's only bookkeeping: it marks which result
  // slots carry admitted work, and its OR reduction is what tells the caller
  // the pipeline has drained and a new weight tile may be published.
  //---------------------------------------------------------------------------
  logic [LATENCY-1:0] valid_pipe_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      valid_pipe_q <= '0;
    end else begin
      valid_pipe_q <= {valid_pipe_q[LATENCY-2:0], a_valid};
    end
  end

  assign res_valid = valid_pipe_q[LATENCY-1];
  assign busy      = a_valid || (valid_pipe_q != '0);

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (ROWS < 2) begin
      $fatal(1, "systolic_array: ROWS must be >= 2 (got %0d)", ROWS);
    end
    if (COLS < 2) begin
      $fatal(1, "systolic_array: COLS must be >= 2 (got %0d)", COLS);
    end
    if (ACC_WIDTH < 2 * DATA_WIDTH + $clog2(ROWS)) begin
      $fatal(1, {"systolic_array: ACC_WIDTH (%0d) is too narrow for a column ",
                 "sum of %0d products of %0d-bit operands; it needs %0d bits"},
             ACC_WIDTH, ROWS, DATA_WIDTH, 2 * DATA_WIDTH + $clog2(ROWS));
    end
  end

  // Publishing a weight tile while vectors are still inside the array leaves
  // those vectors accumulating against a mixture of two tiles. The result is
  // numbers that are wrong by an amount that depends on where each vector had
  // reached, which is close to undebuggable from the outside.
  property p_commit_only_when_drained;
    @(posedge clk) disable iff (!rst_n) (w_commit |-> !busy);
  endproperty
  a_commit_only_when_drained : assert property (p_commit_only_when_drained)
    else $error("systolic_array: weight commit while %0d vector(s) in flight",
                $countones(valid_pipe_q));

  // Loading a weight row while vectors are in flight is harmless - the shadow
  // registers are not what the multipliers read - but it is almost always a
  // sign that the caller believes the array is idle when it is not.
  property p_no_load_during_compute;
    @(posedge clk) disable iff (!rst_n) (w_valid |-> !a_valid);
  endproperty
  a_no_load_during_compute : assert property (p_no_load_during_compute)
    else $error({"systolic_array: weight row pushed in the same cycle as an ",
                 "activation vector"});
`endif

endmodule

`default_nettype wire
