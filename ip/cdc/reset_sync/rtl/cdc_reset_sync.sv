//=============================================================================
// Module      : cdc_reset_sync
// Category    : cdc
// Description : Reset synchroniser - asynchronous assertion, synchronous
//               release.
//
// A raw power-on or system reset is asynchronous to every clock in the design.
// Asserting it asynchronously is what makes the design reach a known state
// even before the clocks are running, and that behaviour is wanted. Releasing
// it asynchronously is not: if the release edge lands inside a flip-flop's
// recovery or removal window, that flip-flop can go metastable and start in an
// unknown state. Different flip-flops can even leave reset on different
// clock cycles, which corrupts any state machine that assumes all of its bits
// left reset together.
//
// This block gives each clock domain a reset that asserts the instant the
// asynchronous input asserts, and releases synchronously to the local clock:
//
//   assertion  - immediate, no clock required
//   release    - STAGES clock edges after arst_n_in rises
//
// One instance is required per clock domain. Feeding one domain's synchronised
// reset into another domain does not work: the release edge would again be
// asynchronous to the second domain.
//
// Parameters
//   STAGES  Length of the synchroniser chain. 2 is the minimum, 3 is used at
//           high clock rates or where the reliability target is high.
//
// Latency     : release is STAGES clock cycles after arst_n_in rises
// Reset       : this block *is* the reset path; it has no other reset
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module cdc_reset_sync #(
    parameter int unsigned STAGES = 2
) (
    // Destination clock domain
    input  wire  clk,

    // Raw asynchronous reset, active low. Typically the power-on reset or a
    // system reset that has no timing relationship to clk.
    input  wire  arst_n_in,

    // Synchronised reset for this clock domain, active low.
    output logic rst_n_out
);

  //---------------------------------------------------------------------------
  // Synchroniser chain.
  //
  // Every stage is cleared asynchronously by arst_n_in, which is what makes
  // the assertion immediate and clock-independent. On release, a constant 1
  // is shifted in, so the output rises STAGES clock edges later. Each stage
  // after the first gives any metastability from the release edge a further
  // full clock period to resolve.
  //
  // Note that only the *release* edge is a timing hazard here. The assertion
  // needs no resolution time because it drives every stage directly.
  //---------------------------------------------------------------------------
  logic [STAGES-1:0] sync_q;

  always_ff @(posedge clk or negedge arst_n_in) begin
    if (!arst_n_in) begin
      sync_q <= '0;
    end else begin
      sync_q <= {sync_q[STAGES-2:0], 1'b1};
    end
  end

  assign rst_n_out = sync_q[STAGES-1];

  //---------------------------------------------------------------------------
  // Elaboration-time checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (STAGES < 2) begin
      $fatal(1, {"cdc_reset_sync: STAGES must be >= 2 (got %0d); a single ",
                 "flop gives the release edge no resolution time"}, STAGES);
    end
  end

  // The output must never rise without the input already being high: a
  // release that outruns its source would mean the chain has been optimised
  // away.
  property p_release_follows_input;
    @(posedge clk) $rose(rst_n_out) |-> arst_n_in;
  endproperty
  a_release_follows_input : assert property (p_release_follows_input)
    else $error("cdc_reset_sync: rst_n_out released while arst_n_in was low");
`endif

endmodule

`default_nettype wire
