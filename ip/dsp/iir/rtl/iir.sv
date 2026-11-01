//=============================================================================
// Module      : iir
// Category    : dsp
// Description : Second-order IIR section (biquad), direct form I, one sample
//               per cycle, with run-time coefficients, rounding and
//               saturation.
//
//   y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]
//
// Higher-order filters are cascades of these sections: every IIR design
// tool factors a filter into second-order sections, and a cascade of
// biquads is far less sensitive to coefficient quantisation than one
// high-order section.
//
// FIXED POINT
//   Coefficients are COEF_WIDTH-bit signed with COEF_FRAC fractional bits:
//   with the defaults they span [-2, 2), which holds every stable a1. The
//   five products are summed exactly, then
//
//     y = saturate(round(sum / 2**COEF_FRAC))
//
//   with rounding half up (add half an LSB, shift arithmetically) and
//   saturation to DATA_WIDTH. The state keeps the saturated y: a filter
//   that overflows clips instead of wrapping, which is what stops an
//   overflow from turning into a full-scale oscillation. m_saturated flags
//   every output that was clipped.
//
// STRUCTURE
//   Direct form I: two input delays and two output delays, all DATA_WIDTH
//   wide. It needs twice the state of direct form II, and in exchange has a
//   single rounding point and no internal node that can overflow - the
//   form that is safe in fixed point. The feedback path, from y[n-1]
//   through a multiplier and the adder to y[n], is the critical path and
//   cannot be pipelined without changing the filter.
//
// COEFFICIENTS
//   coef_wr_en writes coef_data at coef_addr: 0 b0, 1 b1, 2 b2, 3 a1, 4 a2.
//   Other addresses are ignored. A sample uses the coefficients as they are
//   when it is accepted. They reset to zero.
//
// FLOW CONTROL
//   s_ready = !m_valid || m_ready: one sample per cycle, and every register
//   holds under a stall.
//
// Parameters
//   DATA_WIDTH  Signed sample width. 2 to 32.
//   COEF_WIDTH  Signed coefficient width. 2 to 32.
//   COEF_FRAC   Fractional bits of the coefficients. 0 to COEF_WIDTH-1.
//
// Latency     : one cycle.
// Reset       : asynchronous assertion, synchronous release, active low.
//               State and coefficients zero, output empty.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module iir #(
    parameter int unsigned DATA_WIDTH = 16,
    parameter int unsigned COEF_WIDTH = 18,
    parameter int unsigned COEF_FRAC  = 16
) (
    input  wire                          clk,
    input  wire                          rst_n,

    // Coefficient write port: 0 b0, 1 b1, 2 b2, 3 a1, 4 a2
    input  wire                          coef_wr_en,
    input  wire  [2:0]                   coef_addr,
    input  wire  signed [COEF_WIDTH-1:0] coef_data,

    // Input samples
    input  wire                          s_valid,
    output logic                         s_ready,
    input  wire  signed [DATA_WIDTH-1:0] s_data,

    // Output samples
    output logic                         m_valid,
    input  wire                          m_ready,
    output logic signed [DATA_WIDTH-1:0] m_data,
    output logic                         m_saturated
);

  localparam int unsigned P_WIDTH   = DATA_WIDTH + COEF_WIDTH;
  localparam int unsigned ACC_WIDTH = P_WIDTH + 3;     // five products

  localparam logic signed [ACC_WIDTH-1:0] Y_MAX = ACC_WIDTH'((64'sd1 <<< (DATA_WIDTH - 1)) - 1);
  localparam logic signed [ACC_WIDTH-1:0] Y_MIN = ACC_WIDTH'(-(64'sd1 <<< (DATA_WIDTH - 1)));

  logic signed [COEF_WIDTH-1:0] b0, b1, b2, a1, a2;
  logic signed [DATA_WIDTH-1:0] x1, x2, y1, y2;
  logic                         take;

  assign s_ready = !m_valid || m_ready;
  assign take    = s_valid && s_ready;

  //---------------------------------------------------------------------------
  // Coefficients
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      b0 <= '0; b1 <= '0; b2 <= '0; a1 <= '0; a2 <= '0;
    end else if (coef_wr_en) begin
      unique case (coef_addr)
        3'd0:    b0 <= coef_data;
        3'd1:    b1 <= coef_data;
        3'd2:    b2 <= coef_data;
        3'd3:    a1 <= coef_data;
        3'd4:    a2 <= coef_data;
        default: ;
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // The difference equation
  //---------------------------------------------------------------------------
  // Operands are sign-extended to the product width before each multiply, as
  // in the multiplier IP, so every product is exact.
  logic signed [P_WIDTH-1:0]   p_b0, p_b1, p_b2, p_a1, p_a2;
  logic signed [ACC_WIDTH-1:0] acc, rounded, shifted;
  logic signed [DATA_WIDTH-1:0] y;
  logic                         clipped;

  assign p_b0 = P_WIDTH'(s_data) * P_WIDTH'(b0);
  assign p_b1 = P_WIDTH'(x1)     * P_WIDTH'(b1);
  assign p_b2 = P_WIDTH'(x2)     * P_WIDTH'(b2);
  assign p_a1 = P_WIDTH'(y1)     * P_WIDTH'(a1);
  assign p_a2 = P_WIDTH'(y2)     * P_WIDTH'(a2);

  assign acc = ACC_WIDTH'(p_b0) + ACC_WIDTH'(p_b1) + ACC_WIDTH'(p_b2)
             - ACC_WIDTH'(p_a1) - ACC_WIDTH'(p_a2);

  generate
    if (COEF_FRAC == 0) begin : g_no_round
      assign rounded = acc;
    end else begin : g_round
      assign rounded = acc + ACC_WIDTH'(64'sd1 <<< (COEF_FRAC - 1));
    end
  endgenerate

  assign shifted = rounded >>> COEF_FRAC;
  assign clipped = (shifted > Y_MAX) || (shifted < Y_MIN);
  assign y       = (shifted > Y_MAX) ? DATA_WIDTH'(Y_MAX)
                 : (shifted < Y_MIN) ? DATA_WIDTH'(Y_MIN)
                 : DATA_WIDTH'(shifted);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      x1 <= '0; x2 <= '0; y1 <= '0; y2 <= '0;
      m_valid     <= 1'b0;
      m_data      <= '0;
      m_saturated <= 1'b0;
    end else begin
      if (take) begin
        x1 <= s_data;
        x2 <= x1;
        y1 <= y;
        y2 <= y1;
        m_data      <= y;
        m_saturated <= clipped;
        m_valid     <= 1'b1;
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
    if (DATA_WIDTH < 2 || DATA_WIDTH > 32 || COEF_WIDTH < 2 || COEF_WIDTH > 32) begin
      $fatal(1, "iir: DATA_WIDTH and COEF_WIDTH must be 2 to 32");
    end
    if (COEF_FRAC >= COEF_WIDTH) begin
      $fatal(1, "iir: COEF_FRAC must be below COEF_WIDTH (got %0d)", COEF_FRAC);
    end
  end

  property p_output_held;
    @(posedge clk) disable iff (!rst_n)
      (m_valid && !m_ready) |=> (m_valid && $stable(m_data) && $stable(m_saturated));
  endproperty
  a_output_held : assert property (p_output_held)
    else $error("iir: output changed before m_ready");
`endif

endmodule

`default_nettype wire
