//=============================================================================
// Module      : cdc_pulse_sync
// Category    : cdc
// Description : Transfers a single-cycle pulse (an event) between clock
//               domains of arbitrary, unrelated frequencies.
//
// A pulse cannot be carried across a domain boundary by a plain synchroniser.
// If the source clock is faster than the destination, a one-cycle pulse can
// fall entirely between two destination sampling edges and be lost. If the
// source is slower, the same pulse is sampled on several consecutive
// destination edges and arrives as a burst.
//
// The standard solution, implemented here, is to convert the event into a
// level change that cannot be missed:
//
//   1. Each accepted source pulse toggles a flip-flop in the source domain.
//   2. The toggle level crosses to the destination through a synchroniser.
//      A level survives any clock ratio: it is still there on the next edge.
//   3. The destination detects the edge of the synchronised toggle and emits
//      one destination-domain pulse.
//   4. The destination toggle is fed back through a second synchroniser so the
//      source knows the event has been consumed.
//
// Step 4 is what makes the block safe rather than merely usually correct. The
// round trip takes several cycles, and a second pulse arriving inside that
// window would toggle the source flip-flop back, cancelling the first event
// entirely. src_busy exports that window so the source can hold off, and the
// block ignores any pulse presented while busy rather than silently losing it.
//
// Parameters
//   STAGES  Synchroniser depth used in both directions.
//
// Latency     : 2 to 3 src cycles + STAGES dst cycles, input pulse to output
// Throughput  : one event per round trip; watch src_busy
// Reset       : asynchronous assertion, synchronous release, active low, one
//               reset per domain
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module cdc_pulse_sync #(
    parameter int unsigned STAGES = 2
) (
    // Source clock domain
    input  wire  src_clk,
    input  wire  src_rst_n,
    input  wire  src_pulse,     // one-cycle request; ignored while src_busy
    output logic src_busy,      // an event is in flight; do not present another

    // Destination clock domain
    input  wire  dst_clk,
    input  wire  dst_rst_n,
    output logic dst_pulse      // one-cycle pulse, one per accepted src_pulse
);

  //---------------------------------------------------------------------------
  // Source domain: convert an accepted pulse into a level toggle.
  //
  // src_pulse is deliberately qualified with !src_busy. Accepting a second
  // event while the first is in flight would toggle src_toggle_q back to its
  // previous value, and the destination would see no edge at all: both events
  // would vanish. Dropping the event is the lesser evil, and src_busy tells
  // the source it happened.
  //---------------------------------------------------------------------------
  logic src_toggle_q;
  logic src_accept;

  assign src_accept = src_pulse && !src_busy;

  always_ff @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n) begin
      src_toggle_q <= 1'b0;
    end else if (src_accept) begin
      src_toggle_q <= ~src_toggle_q;
    end
  end

  //---------------------------------------------------------------------------
  // Source toggle -> destination domain.
  //---------------------------------------------------------------------------
  logic dst_toggle_sync;
  logic dst_toggle_q;

  cdc_sync_2ff #(
      .WIDTH       (1),
      .STAGES      (STAGES),
      .RESET_VALUE (1'b0)
  ) u_sync_to_dst (
      .clk     (dst_clk),
      .rst_n   (dst_rst_n),
      .d_async (src_toggle_q),
      .q_sync  (dst_toggle_sync)
  );

  //---------------------------------------------------------------------------
  // Destination domain: edge detect the synchronised toggle.
  //
  // Either edge is an event, because the source alternates the level rather
  // than pulsing it.
  //---------------------------------------------------------------------------
  always_ff @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n) begin
      dst_toggle_q <= 1'b0;
      dst_pulse    <= 1'b0;
    end else begin
      dst_toggle_q <= dst_toggle_sync;
      dst_pulse    <= dst_toggle_sync ^ dst_toggle_q;
    end
  end

  //---------------------------------------------------------------------------
  // Destination acknowledgement -> source domain.
  //
  // The acknowledgement is the destination's copy of the toggle, not a new
  // signal: once the source sees its own toggle value reflected back, the
  // event has definitely been consumed and the next one may be accepted.
  //---------------------------------------------------------------------------
  logic src_ack_sync;

  cdc_sync_2ff #(
      .WIDTH       (1),
      .STAGES      (STAGES),
      .RESET_VALUE (1'b0)
  ) u_sync_to_src (
      .clk     (src_clk),
      .rst_n   (src_rst_n),
      .d_async (dst_toggle_q),
      .q_sync  (src_ack_sync)
  );

  // Busy for as long as the source's toggle has not come back around.
  assign src_busy = src_toggle_q ^ src_ack_sync;

  //---------------------------------------------------------------------------
  // Elaboration-time checks and protocol assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (STAGES < 2) begin
      $fatal(1, {"cdc_pulse_sync: STAGES must be >= 2 (got %0d); a single ",
                 "flop provides no metastability resolution time"}, STAGES);
    end
  end

  // Presenting a pulse while busy is a protocol error in the surrounding
  // logic: the event is dropped, so the source must check src_busy first.
  property p_no_pulse_while_busy;
    @(posedge src_clk) disable iff (!src_rst_n)
      src_pulse |-> !src_busy;
  endproperty
  a_no_pulse_while_busy : assert property (p_no_pulse_while_busy)
    else $error("cdc_pulse_sync: src_pulse asserted while src_busy; event dropped");

  // A destination pulse is exactly one cycle wide.
  property p_dst_pulse_single_cycle;
    @(posedge dst_clk) disable iff (!dst_rst_n)
      dst_pulse |=> !dst_pulse;
  endproperty
  a_dst_pulse_single_cycle : assert property (p_dst_pulse_single_cycle)
    else $error("cdc_pulse_sync: dst_pulse was wider than one cycle");
`endif

endmodule

`default_nettype wire
