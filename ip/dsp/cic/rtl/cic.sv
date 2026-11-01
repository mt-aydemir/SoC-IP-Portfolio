//=============================================================================
// Module      : cic
// Category    : dsp
// Description : Cascaded integrator-comb (Hogenauer) decimator with a run-time
//               decimation rate and a full-precision output.
//
// A CIC filter decimates by R with no multiplier at all: STAGES integrators
// at the input rate, a rate change, and STAGES combs at the output rate. Its
// response is that of STAGES cascaded moving sums of length R*M, which is why
// it is the first stage of almost every digital down-converter - it takes the
// rate down cheaply, and a short FIR after it corrects the droop.
//
// STRUCTURE
//   integrators  i[0] <= i[0] + x;  i[s] <= i[s] + i[s-1]  (register values)
//                Each stage adds the previous stage's register, so the chain
//                is pipelined: one adder per path, STAGES-1 samples of pure
//                delay, no effect on the response.
//   decimation   every rate-th accepted sample passes i[STAGES-1] to the combs
//   combs        c[s] = c[s-1] - (c[s-1], DIFF_DELAY outputs ago), at the
//                output rate, into the output register
//
// PRECISION
//   The gain is (rate * DIFF_DELAY) ** STAGES, and Hogenauer's result is that
//   OUT_WIDTH = DATA_WIDTH + STAGES * log2(MAX_RATE * DIFF_DELAY) bits hold
//   every output exactly. The integrators do overflow - they grow without
//   bound on any input with a DC component - but every register is
//   OUT_WIDTH wide and wraps, and two's-complement wrap-around is exact
//   modulo 2**OUT_WIDTH, so the combs' differences undo it. Nothing here may
//   saturate: saturation would break exactly that argument.
//
// RATE
//   rate is sampled every input sample; it must be 1 to MAX_RATE. A new
//   value takes effect at the next decimation point - change it between
//   bursts, since the outputs straddling the change mix two rates.
//
// FLOW CONTROL
//   An input sample is refused only when it would produce an output and the
//   output register is still full: s_ready = !(due && m_valid && !m_ready).
//   At every other sample the input runs at one sample per cycle.
//
// Parameters
//   STAGES      Number of integrator/comb pairs, N. 1 to 8.
//   MAX_RATE    Largest decimation rate. 2 to 65536.
//   DIFF_DELAY  Comb differential delay, M. 1 or 2.
//   DATA_WIDTH  Signed input width. 2 to 32.
//
// Latency     : the output for a decimation point is registered on the edge
//               that accepts its sample.
// Reset       : asynchronous assertion, synchronous release, active low.
//               Integrators, combs and the phase counter zero.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module cic #(
    parameter int unsigned STAGES     = 4,
    parameter int unsigned MAX_RATE   = 64,
    parameter int unsigned DIFF_DELAY = 1,
    parameter int unsigned DATA_WIDTH = 16
) (
    input  wire                              clk,
    input  wire                              rst_n,

    // Decimation rate, 1 to MAX_RATE
    input  wire  [$clog2(MAX_RATE+1)-1:0]    rate,

    // Input samples
    input  wire                              s_valid,
    output logic                             s_ready,
    input  wire  signed [DATA_WIDTH-1:0]     s_data,

    // Output samples, one per rate inputs, full precision
    output logic                             m_valid,
    input  wire                              m_ready,
    output logic signed [DATA_WIDTH+STAGES*$clog2(MAX_RATE*DIFF_DELAY)-1:0] m_data
);

  localparam int unsigned OUT_WIDTH = DATA_WIDTH + STAGES * $clog2(MAX_RATE * DIFF_DELAY);
  localparam int unsigned RW        = $clog2(MAX_RATE + 1);
  localparam int unsigned CW        = $clog2(MAX_RATE);

  logic signed [OUT_WIDTH-1:0] integ [STAGES];
  logic [CW-1:0]               phase;
  logic                        due, take;

  // The comb delay lines: DIFF_DELAY previous inputs of each comb stage.
  logic signed [OUT_WIDTH-1:0] delay [STAGES][DIFF_DELAY];
  logic signed [OUT_WIDTH-1:0] comb  [STAGES+1];

  assign due     = (32'(phase) + 1 >= 32'(rate));
  assign s_ready = !(due && m_valid && !m_ready);
  assign take    = s_valid && s_ready;

  //---------------------------------------------------------------------------
  // Integrators and the decimation phase, at the input rate
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < STAGES; s++) integ[s] <= '0;
      phase <= '0;
    end else if (take) begin
      integ[0] <= integ[0] + OUT_WIDTH'(s_data);
      for (int s = 1; s < STAGES; s++) integ[s] <= integ[s] + integ[s-1];
      phase <= due ? '0 : phase + 1'b1;
    end
  end

  //---------------------------------------------------------------------------
  // Combs, at the output rate
  //---------------------------------------------------------------------------
  // One process, so the chain through the array is not mistaken for a
  // combinational loop.
  always_comb begin
    comb[0] = integ[STAGES-1];
    for (int s = 0; s < STAGES; s++) comb[s+1] = comb[s] - delay[s][DIFF_DELAY-1];
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int s = 0; s < STAGES; s++) begin
        for (int d = 0; d < DIFF_DELAY; d++) delay[s][d] <= '0;
      end
      m_valid <= 1'b0;
      m_data  <= '0;
    end else begin
      if (take && due) begin
        for (int s = 0; s < STAGES; s++) begin
          delay[s][0] <= comb[s];
          for (int d = 1; d < DIFF_DELAY; d++) delay[s][d] <= delay[s][d-1];
        end
        m_data  <= comb[STAGES];
        m_valid <= 1'b1;
      end else if (m_ready) begin
        m_valid <= 1'b0;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (STAGES < 1 || STAGES > 8) begin
      $fatal(1, "cic: STAGES must be 1 to 8 (got %0d)", STAGES);
    end
    if (MAX_RATE < 2 || MAX_RATE > 65536) begin
      $fatal(1, "cic: MAX_RATE must be 2 to 65536 (got %0d)", MAX_RATE);
    end
    if (DIFF_DELAY < 1 || DIFF_DELAY > 2) begin
      $fatal(1, "cic: DIFF_DELAY must be 1 or 2 (got %0d)", DIFF_DELAY);
    end
    if (DATA_WIDTH < 2 || DATA_WIDTH > 32) begin
      $fatal(1, "cic: DATA_WIDTH must be 2 to 32 (got %0d)", DATA_WIDTH);
    end
  end

  property p_rate_legal;
    @(posedge clk) disable iff (!rst_n)
      s_valid |-> (rate >= RW'(1) && 32'(rate) <= MAX_RATE);
  endproperty
  a_rate_legal : assert property (p_rate_legal)
    else $error("cic: rate %0d outside 1..%0d", rate, MAX_RATE);

  property p_output_held;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready) |=> (m_valid && $stable(m_data));
  endproperty
  a_output_held : assert property (p_output_held)
    else $error("cic: output changed before m_ready");
`endif

endmodule

`default_nettype wire
