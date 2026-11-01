//=============================================================================
// Module      : template_ip
// Category    : <category>
// Description : One-paragraph statement of what the block does, written for
//               an integrator who has never seen it before.
//
// Expand on the behaviour here: the algorithm, the latency, the throughput,
// what happens on back-pressure and what the reset state is. Everything an
// integrator needs in order to use the block correctly belongs in this header
// and in docs/, not in the body of the code.
//
// Parameters
//   DATA_WIDTH  Width of the data path in bits. Must be >= 1.
//
// Interfaces
//   clk / rst_n            single clock, active-low asynchronous reset
//   s_valid / s_ready      ready/valid input stream
//   m_valid / m_ready      ready/valid output stream
//
// Protocol
//   A transfer happens on any rising clock edge where valid and ready are both
//   high. Once asserted, valid must stay asserted with stable data until the
//   transfer completes; ready may be withdrawn freely.
//
// Latency     : 1 clock cycle, fully pipelined
// Throughput  : one transfer per cycle when the sink does not stall
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module template_ip #(
    parameter int unsigned DATA_WIDTH = 8
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // Input stream
    input  wire                   s_valid,
    output logic                  s_ready,
    input  wire  [DATA_WIDTH-1:0] s_data,

    // Output stream
    output logic                  m_valid,
    input  wire                   m_ready,
    output logic [DATA_WIDTH-1:0] m_data
);

  //---------------------------------------------------------------------------
  // A single skid-free register stage: accept a new word whenever the output
  // register is empty or is being drained in the same cycle.
  //---------------------------------------------------------------------------
  assign s_ready = m_ready || !m_valid;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_valid <= 1'b0;
      m_data  <= '0;
    end else if (s_ready) begin
      m_valid <= s_valid;
      if (s_valid) begin
        m_data <= s_data;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time parameter checks and protocol assertions.
  //
  // Both are compiled out under `SYNTHESIS so that no simulation-only
  // construct ever reaches a synthesis tool.
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DATA_WIDTH < 1) begin
      $fatal(1, "template_ip: DATA_WIDTH must be >= 1 (got %0d)", DATA_WIDTH);
    end
  end

  // Data must not change while a transfer is stalled.
  property p_stable_payload;
    @(posedge clk) disable iff (!rst_n)
      (s_valid && !s_ready) |=> $stable(s_data);
  endproperty
  a_stable_payload : assert property (p_stable_payload)
    else $error("template_ip: s_data changed while the transfer was stalled");

  // Valid must not be withdrawn before the transfer completes.
  property p_valid_held;
    @(posedge clk) disable iff (!rst_n)
      (s_valid && !s_ready) |=> s_valid;
  endproperty
  a_valid_held : assert property (p_valid_held)
    else $error("template_ip: s_valid was withdrawn before ready");
`endif

endmodule

`default_nettype wire
