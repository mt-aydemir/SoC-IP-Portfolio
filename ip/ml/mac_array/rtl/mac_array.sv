//=============================================================================
// Module      : mac_array
// Category    : ml
// Description : LANES-wide multiply-accumulate array: a pipelined dot-product
//               engine that multiplies LANES operand pairs per cycle, sums
//               them through a registered adder tree, and accumulates the
//               sums over the beats of a vector.
//
// The block computes one dot product per input vector, however long:
//
//     m_data = sum over beats, sum over lanes i of  a[i] * b[i]
//
// A vector is a sequence of beats, LANES pairs each, ended by s_last. A
// fully connected layer, a 1x1 convolution or one output of any longer
// convolution is a dot product of this kind: the vector length is the
// reduction depth, and it need not be a multiple of anything - a short last
// beat is padded with zero operands by the user.
//
// systolic_array computes a tile of dot products at once and needs its
// weights held in place; this block computes one at a time from two
// streams, both operands changing every beat, and accepts back-pressure.
// It is the shape for layers with no weight reuse - fully connected layers
// at batch size one, depthwise convolutions - where a weight-stationary
// array would spend more cycles loading weights than computing.
//
// OPERANDS
//   Lane i of s_a and s_b is bits [i*DATA_WIDTH +: DATA_WIDTH]. A_SIGNED and
//   B_SIGNED choose two's complement or unsigned for each operand, so uint8
//   activations against int8 weights - the usual quantised case - are
//   multiplied exactly. Each product is exact in 2*DATA_WIDTH+1 bits for
//   every signedness, and each beat's sum in that plus $clog2(LANES).
//
// ACCUMULATION
//   The accumulator is ACC_WIDTH bits and wraps modulo 2**ACC_WIDTH, as
//   integer accumulators in every quantised-inference runtime do; the
//   result is exact whenever the true dot product fits ACC_WIDTH bits.
//   ACC_WIDTH must hold at least one beat exactly.
//
// PIPELINE
//   Stage 1 registers the LANES products; stages 2 to 1+$clog2(LANES) are
//   the adder tree, one level per stage; the last stage adds the beat sum to
//   the accumulator and, on s_last, writes the dot product into a small
//   output FIFO, whose head is m_data. Latency is $clog2(LANES) + 2 cycles
//   from the beat carrying s_last to m_valid.
//
// FLOW CONTROL
//   The pipeline never stalls. Instead every accepted last beat takes a
//   credit, returned when its result is taken, and s_ready is high while
//   fewer than DEPTH = $clog2(LANES) + 3 credits are out - so the FIFO, DEPTH
//   entries deep, can never overflow, and with m_ready held high the block
//   accepts one beat per cycle even when every beat ends a vector. s_ready
//   is a register compare: there is no combinational path from m_ready to
//   s_ready, and m_ready does not fan out to the pipeline.
//
// Parameters
//   LANES       Operand pairs per beat. 1 to 64.
//   DATA_WIDTH  Operand width. 2 to 16.
//   ACC_WIDTH   Accumulator and result width. At least
//               2*DATA_WIDTH + 1 + $clog2(LANES), at most 64.
//   A_SIGNED    1: s_a lanes are two's complement; 0: unsigned.
//   B_SIGNED    1: s_b lanes are two's complement; 0: unsigned.
//
// Latency     : $clog2(LANES) + 2 cycles from the last beat to the result.
// Reset       : asynchronous assertion, synchronous release, active low.
//               Pipeline empty, no vector in progress, output empty.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module mac_array #(
    parameter int unsigned LANES      = 16,
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned ACC_WIDTH  = 32,
    parameter int unsigned A_SIGNED   = 1,
    parameter int unsigned B_SIGNED   = 1
) (
    input  wire                         clk,
    input  wire                         rst_n,

    // Operand beats
    input  wire                         s_valid,
    output logic                        s_ready,
    input  wire  [LANES*DATA_WIDTH-1:0] s_a,
    input  wire  [LANES*DATA_WIDTH-1:0] s_b,
    input  wire                         s_last,

    // Dot products
    output logic                        m_valid,
    input  wire                         m_ready,
    output logic [ACC_WIDTH-1:0]        m_data
);

  localparam int unsigned LEVELS = (LANES > 1) ? $clog2(LANES) : 0;
  localparam int unsigned P2     = 1 << LEVELS;          // lanes padded to a power of two
  localparam int unsigned XW     = DATA_WIDTH + 1;       // operand with its sign made explicit
  localparam int unsigned PW     = 2 * DATA_WIDTH + 1;   // exact product
  localparam int unsigned SW     = PW + LEVELS;          // exact beat sum

  localparam int unsigned DEPTH  = LEVELS + 3;          // output FIFO entries and credits
  localparam int unsigned CW     = $clog2(DEPTH + 1);
  localparam int unsigned PTRW   = $clog2(DEPTH);

  logic          take, pop;
  logic [CW-1:0] credits;        // last beats accepted whose results are not yet taken

  assign s_ready = credits < CW'(DEPTH);
  assign take    = s_valid && s_ready;
  assign pop     = m_valid && m_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) credits <= '0;
    else        credits <= credits + CW'(take && s_last) - CW'(pop);
  end

  //---------------------------------------------------------------------------
  // Stage 1: products
  //---------------------------------------------------------------------------
  // Each operand is extended by one bit - its sign bit, or a zero - so that
  // one signed multiply is exact for every combination of signedness.
  logic signed [PW-1:0] prod [P2];
  logic                 v_q  [LEVELS+1];
  logic                 l_q  [LEVELS+1];   // meaningful only with v_q

  for (genvar i = 0; i < P2; i++) begin : g_lane
    if (i < LANES) begin : g_used
      logic signed [XW-1:0] xa, xb;
      logic        [DATA_WIDTH-1:0] ra, rb;
      assign ra = s_a[i*DATA_WIDTH +: DATA_WIDTH];
      assign rb = s_b[i*DATA_WIDTH +: DATA_WIDTH];
      assign xa = {(A_SIGNED != 0) && ra[DATA_WIDTH-1], ra};
      assign xb = {(B_SIGNED != 0) && rb[DATA_WIDTH-1], rb};
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) prod[i] <= '0;
        else        prod[i] <= PW'(xa * xb);
      end
    end else begin : g_pad
      assign prod[i] = '0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      v_q[0] <= 1'b0;
      l_q[0] <= 1'b0;
    end else begin
      v_q[0] <= take;
      l_q[0] <= s_last;       // read only where v_q is set
    end
  end

  //---------------------------------------------------------------------------
  // Stages 2 .. LEVELS+1: the adder tree, one registered level per stage
  //---------------------------------------------------------------------------
  // Level k holds P2 >> k sums of PW+k bits; every sum is exact.
  logic signed [SW-1:0] node [LEVELS+1][P2];

  for (genvar i = 0; i < P2; i++) begin : g_leaf
    assign node[0][i] = SW'(prod[i]);
  end

  for (genvar k = 1; k <= LEVELS; k++) begin : g_level
    for (genvar i = 0; i < (P2 >> k); i++) begin : g_add
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) node[k][i] <= '0;
        else        node[k][i] <= node[k-1][2*i] + node[k-1][2*i+1];
      end
    end
    for (genvar i = (P2 >> k); i < P2; i++) begin : g_unused
      assign node[k][i] = '0;
    end
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        v_q[k] <= 1'b0;
        l_q[k] <= 1'b0;
      end else begin
        v_q[k] <= v_q[k-1];
        l_q[k] <= l_q[k-1];
      end
    end
  end

  //---------------------------------------------------------------------------
  // Last stage: accumulate, and push the dot product on the last beat
  //---------------------------------------------------------------------------
  logic                 in_vector;   // the accumulator holds a partial sum
  logic [ACC_WIDTH-1:0] acc, total;
  logic                 push;

  assign total = (in_vector ? acc : '0) + ACC_WIDTH'(node[LEVELS][0]);
  assign push  = v_q[LEVELS] && l_q[LEVELS];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      in_vector <= 1'b0;
      acc       <= '0;
    end else if (v_q[LEVELS]) begin
      acc       <= total;
      in_vector <= !l_q[LEVELS];
    end
  end

  //---------------------------------------------------------------------------
  // Output FIFO
  //---------------------------------------------------------------------------
  logic [ACC_WIDTH-1:0] fifo [DEPTH];
  logic [PTRW-1:0]      wr_ptr, rd_ptr;
  logic [CW-1:0]        count;

  function automatic logic [PTRW-1:0] next_ptr(input logic [PTRW-1:0] p);
    next_ptr = (32'(p) == DEPTH - 1) ? '0 : p + PTRW'(1);
  endfunction

  assign m_valid = count != '0;
  assign m_data  = fifo[rd_ptr];

  always_ff @(posedge clk) begin
    if (push) fifo[wr_ptr] <= total;
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end else begin
      if (push) wr_ptr <= next_ptr(wr_ptr);
      if (pop)  rd_ptr <= next_ptr(rd_ptr);
      count <= count + CW'(push) - CW'(pop);
    end
  end

  //---------------------------------------------------------------------------
  // Checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (LANES < 1 || LANES > 64) begin
      $fatal(1, "mac_array: LANES must be 1 to 64 (got %0d)", LANES);
    end
    if (DATA_WIDTH < 2 || DATA_WIDTH > 16) begin
      $fatal(1, "mac_array: DATA_WIDTH must be 2 to 16 (got %0d)", DATA_WIDTH);
    end
    if (ACC_WIDTH < SW || ACC_WIDTH > 64) begin
      $fatal(1, "mac_array: ACC_WIDTH must be %0d to 64 (got %0d)", SW, ACC_WIDTH);
    end
  end

  property p_output_held;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready) |=> (m_valid && $stable(m_data));
  endproperty
  a_output_held : assert property (p_output_held)
    else $error("mac_array: result changed before m_ready");

  property p_no_overflow;
    @(posedge clk) disable iff (!rst_n) push |-> (count < CW'(DEPTH) || pop);
  endproperty
  a_no_overflow : assert property (p_no_overflow)
    else $error("mac_array: output FIFO overflow");
`endif

endmodule

`default_nettype wire
