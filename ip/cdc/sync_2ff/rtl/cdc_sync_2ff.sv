//=============================================================================
// Module      : cdc_sync_2ff
// Category    : cdc
// Description : Multi-flop synchroniser for asynchronous single-bit signals.
//
// Transfers one or more *independent* asynchronous bits into the destination
// clock domain through a chain of STAGES flip-flops. The first flip-flop may
// go metastable; each additional stage gives the metastability a further full
// clock period to resolve, which is what makes the mean time between failures
// astronomically large.
//
// IMPORTANT USAGE RULE
//   This synchroniser is only correct for signals whose bits are mutually
//   independent, such as a level-encoded status flag or a set of unrelated
//   interrupt lines. It must NOT be used to transfer a multi-bit value whose
//   bits change together: each bit resolves independently, so the destination
//   domain can observe a combination that never existed at the source. For
//   multi-bit data use one of:
//     - cdc_pulse_sync   : single event transfer with handshake
//     - cdc_async_fifo   : streaming data, Gray-coded pointers
//     - a Gray-coded counter through this module (adjacent codes differ by
//       one bit, so a partially resolved sample is always old-or-new)
//
// Parameters
//   WIDTH       Number of independent bits to synchronise.
//   STAGES      Length of the flip-flop chain. 2 is the industry minimum,
//               3 is common for high clock rates or high reliability targets.
//   RESET_VALUE Value loaded into every stage while rst_n is asserted.
//
// Reset       : asynchronous assertion, synchronous release (active low)
// Clock       : single destination-domain clock
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module cdc_sync_2ff #(
    parameter int unsigned WIDTH  = 1,
    parameter int unsigned STAGES = 2,
    parameter logic [WIDTH-1:0] RESET_VALUE = '0
) (
    // Destination clock domain
    input  wire              clk,
    input  wire              rst_n,

    // Asynchronous input, sampled directly by the first stage
    input  wire  [WIDTH-1:0] d_async,

    // Synchronised output, safe to use in the destination domain
    output logic [WIDTH-1:0] q_sync
);

  //---------------------------------------------------------------------------
  // Synchroniser chain.
  //
  // sync_q[0] is the metastability-prone stage. Nothing in the design may read
  // it; only sync_q[STAGES-1] is exported. Physical implementation must keep
  // the chain from being retimed, merged or spread across the die: constrain
  // it with a false path / max delay in the SDC and, if the target flow
  // supports it, mark the chain as a synchroniser in the tool's own way.
  //---------------------------------------------------------------------------
  logic [WIDTH-1:0] sync_q [STAGES];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int unsigned s = 0; s < STAGES; s++) begin
        sync_q[s] <= RESET_VALUE;
      end
    end else begin
      sync_q[0] <= d_async;
      for (int unsigned s = 1; s < STAGES; s++) begin
        sync_q[s] <= sync_q[s-1];
      end
    end
  end

  assign q_sync = sync_q[STAGES-1];

  //---------------------------------------------------------------------------
  // Elaboration-time checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (STAGES < 2) begin
      $fatal(1, "cdc_sync_2ff: STAGES must be >= 2 (got %0d); a single flop ",
                "provides no metastability resolution time", STAGES);
    end
    if (WIDTH < 1) begin
      $fatal(1, "cdc_sync_2ff: WIDTH must be >= 1 (got %0d)", WIDTH);
    end
  end
`endif

endmodule

`default_nettype wire
