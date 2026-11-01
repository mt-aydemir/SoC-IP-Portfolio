//=============================================================================
// Module      : fir
// Category    : dsp
// Description : Transposed-form FIR filter, one sample per cycle, with
//               run-time loadable coefficients and a full-precision output.
//
//   y[n] = sum over k of h[k] * x[n-k],   k = 0 .. TAPS-1
//
// STRUCTURE
//   Transposed direct form: every accepted sample is multiplied by all TAPS
//   coefficients at once, and each product is added to a partial sum that
//   moves one register towards the output per sample:
//
//     y     <= x*h[0] + z[1]
//     z[k]  <= x*h[k] + z[k+1]        k = 1 .. TAPS-2
//     z[T-1] <= x*h[TAPS-1]
//
//   The longest path is one multiplier and one adder, whatever TAPS is -
//   there is no adder tree - which is why this form, not the direct form,
//   is the usual choice for a full-rate filter.
//
// PRECISION
//   The output is exact. A product of a DATA_WIDTH and a COEF_WIDTH signed
//   number fits DATA_WIDTH+COEF_WIDTH bits, and a sum of TAPS of them needs
//   $clog2(TAPS) more, the most negative times the most negative included:
//   OUT_WIDTH = DATA_WIDTH + COEF_WIDTH + $clog2(TAPS). No sum can overflow,
//   so there is nothing to saturate. Scaling the result is the integrator's
//   choice - requant_int8, or a slice of the bits.
//
// COEFFICIENTS
//   coef_wr_en writes coef_data to h[coef_addr] on the edge; an address at
//   or beyond TAPS is ignored. Every product
//   uses the coefficients as they are when its sample is accepted, so after
//   a write, outputs already in progress keep their old products: the new
//   value is fully in effect TAPS samples later. Load coefficients while the
//   stream is idle to avoid the blend. They reset to zero.
//
// FLOW CONTROL
//   s_ready = !m_valid || m_ready: a sample is accepted whenever the output
//   register is free or being emptied, so the filter runs at one sample per
//   cycle under no back-pressure and holds every register under a stall.
//
// Parameters
//   TAPS        Number of coefficients. 2 to 256.
//   DATA_WIDTH  Signed input sample width. 2 to 32.
//   COEF_WIDTH  Signed coefficient width. 2 to 32.
//
// Latency     : one cycle from an accepted sample to its output.
// Reset       : asynchronous assertion, synchronous release, active low.
//               Delay line and coefficients zero, output empty.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module fir #(
    parameter int unsigned TAPS       = 16,
    parameter int unsigned DATA_WIDTH = 16,
    parameter int unsigned COEF_WIDTH = 16
) (
    input  wire                                             clk,
    input  wire                                             rst_n,

    // Coefficient write port
    input  wire                                             coef_wr_en,
    input  wire  [$clog2(TAPS)-1:0]                         coef_addr,
    input  wire  signed [COEF_WIDTH-1:0]                    coef_data,

    // Input samples
    input  wire                                             s_valid,
    output logic                                            s_ready,
    input  wire  signed [DATA_WIDTH-1:0]                    s_data,

    // Output samples, full precision
    output logic                                            m_valid,
    input  wire                                             m_ready,
    output logic signed [DATA_WIDTH+COEF_WIDTH+$clog2(TAPS)-1:0] m_data
);

  localparam int unsigned P_WIDTH   = DATA_WIDTH + COEF_WIDTH;
  localparam int unsigned OUT_WIDTH = P_WIDTH + $clog2(TAPS);

  logic signed [COEF_WIDTH-1:0] coef [TAPS];
  logic signed [OUT_WIDTH-1:0]  z    [1:TAPS-1];
  logic signed [OUT_WIDTH-1:0]  prod [TAPS];
  logic                         take;

  assign s_ready = !m_valid || m_ready;
  assign take    = s_valid && s_ready;

  for (genvar k = 0; k < TAPS; k++) begin : g_prod
    // Both operands are sign-extended to the product width before the
    // multiply, as in the multiplier IP, so the product is exact; it is then
    // sign-extended to the accumulation width.
    logic signed [P_WIDTH-1:0] p;

    assign p       = P_WIDTH'(s_data) * P_WIDTH'(coef[k]);
    assign prod[k] = OUT_WIDTH'(p);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int k = 0; k < TAPS; k++) coef[k] <= '0;
    end else if (coef_wr_en && 32'(coef_addr) < TAPS) begin
      coef[coef_addr] <= coef_data;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int k = 1; k < TAPS; k++) z[k] <= '0;
      m_valid <= 1'b0;
      m_data  <= '0;
    end else begin
      if (take) begin
        m_data <= prod[0] + z[1];
        for (int k = 1; k < TAPS - 1; k++) z[k] <= prod[k] + z[k+1];
        z[TAPS-1] <= prod[TAPS-1];
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
    if (TAPS < 2 || TAPS > 256) begin
      $fatal(1, "fir: TAPS must be 2 to 256 (got %0d)", TAPS);
    end
    if (DATA_WIDTH < 2 || DATA_WIDTH > 32 || COEF_WIDTH < 2 || COEF_WIDTH > 32) begin
      $fatal(1, "fir: DATA_WIDTH and COEF_WIDTH must be 2 to 32");
    end
  end

  property p_output_held;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready) |=> (m_valid && $stable(m_data));
  endproperty
  a_output_held : assert property (p_output_held)
    else $error("fir: output changed before m_ready");
`endif

endmodule

`default_nettype wire
