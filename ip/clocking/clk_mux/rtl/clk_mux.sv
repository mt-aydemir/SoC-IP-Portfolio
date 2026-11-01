//=============================================================================
// Module      : clk_mux
// Category    : clocking
// Description : Glitch-free multiplexer between two asynchronous clocks.
//
// Switching clocks with a plain multiplexer produces a glitch whenever the
// select changes while either clock is high: the output jumps from one clock's
// level to the other's, which can create a pulse arbitrarily narrower than
// either source period. Downstream flip-flops then see a clock edge that
// violates their minimum pulse width, and the result is silent, unreproducible
// corruption.
//
// The standard solution, implemented here, makes the two clocks cooperate:
//
//   1. Each clock owns a two-stage synchroniser holding its own "I am
//      selected" flag.
//   2. Each flag is qualified with the *other* clock's flag inverted, so at
//      most one clock can be enabled at any instant. The dead time between one
//      clock releasing and the other taking over is what removes the glitch.
//   3. The final stage of each synchroniser is clocked on the falling edge, so
//      the enable presented to the AND gate changes only while its clock is
//      low - the same principle as clk_gate.
//
// The cost is latency: a switch takes two to three cycles of the outgoing
// clock plus two to three of the incoming one, and the output is held low in
// between. Both clocks must be running for a switch to complete. If the
// outgoing clock has stopped, the block stays parked with the output low
// rather than glitching, which is the safe failure.
//
// USAGE RULE
//   select must be held stable until clk_active has followed it. This is a
//   requirement of every glitch-free clock multiplexer, including hard macro
//   cells, and it is why clk_active exists: it reports which clock is actually
//   driving the output, so the integrator never has to guess when the
//   changeover finished.
//
//     always_ff @(posedge clk_cfg or negedge rst_n_cfg)
//       if (!rst_n_cfg)                 select <= 1'b0;
//       else if (select == clk_active)  select <= requested_clock;
//
//   Withdrawing a request mid-changeover is handled safely - each branch's
//   chain is cleared, not shifted, so no stale request can complete behind the
//   withdrawal - but issuing a new request before the previous one has landed
//   simply delays the switch.
//
// Parameters
//   STAGES  Synchroniser depth in each branch. 2 is the minimum.
//
// Latency     : ~STAGES cycles of each clock; output low during the changeover
// Reset       : asynchronous assertion, synchronous release, active low.
//               Reset selects clk0.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module clk_mux #(
    parameter int unsigned STAGES = 2
) (
    input  wire  clk0,
    input  wire  clk1,

    // One reset per clock branch. Each is released synchronously to its own
    // clock; see cdc_reset_sync.
    input  wire  rst0_n,
    input  wire  rst1_n,

    // Clock selection. Asynchronous to both clocks; each branch synchronises
    // it locally, so no external synchroniser is needed.
    input  wire  select,

    // Which clock is actually driving the output: 0 for clk0, 1 for clk1.
    // Hold select stable until clk_active matches it.
    output wire  clk_active,

    output wire  clk_out
);

  //---------------------------------------------------------------------------
  // Per-branch "selected" requests. Each is qualified with the other branch's
  // whole state - its enable *and* every stage of its chain - so a branch can
  // only begin to take over once the other has fully released and has nothing
  // in flight. This mutual exclusion is what guarantees the two AND gates are
  // never open at the same time.
  //
  // Qualifying with the enable alone is not enough. A request whose chain has
  // already filled, but whose falling-edge enable has not yet followed, is
  // invisible to the other branch for up to half a period; a select that turns
  // back inside that window lets both branches complete. In the clock's own
  // domain "chain non-zero or enable high" has no gap, so watching both closes
  // the window.
  //---------------------------------------------------------------------------
  logic [STAGES-1:0] sel0_q;
  logic [STAGES-1:0] sel1_q;
  logic              enable0;
  logic              enable1;

  logic              request0;
  logic              request1;

  assign request0 = ~select & ~enable1 & ~(|sel1_q);
  assign request1 =  select & ~enable0 & ~(|sel0_q);

  //---------------------------------------------------------------------------
  // Branch 0
  //---------------------------------------------------------------------------
  // The chain is cleared rather than shifted when the request is withdrawn.
  // A plain shift register would let a 1 that is already in flight continue to
  // the output after the request had gone, so a select that toggles during a
  // changeover could enable both branches at once - the exact glitch this
  // block exists to prevent. Clearing means an enable can only ever rise after
  // STAGES *consecutive* cycles of a held request.
  always_ff @(posedge clk0 or negedge rst0_n) begin
    if (!rst0_n) begin
      // Reset selects clk0, so branch 0 comes up already requesting.
      sel0_q <= {STAGES{1'b1}};
    end else if (!request0) begin
      sel0_q <= '0;
    end else begin
      sel0_q <= {sel0_q[STAGES-2:0], 1'b1};
    end
  end

  // Final stage on the falling edge: the enable then changes only while clk0
  // is low, so the AND gate below can never chop a pulse.
  always_ff @(negedge clk0 or negedge rst0_n) begin
    if (!rst0_n) begin
      enable0 <= 1'b1;
    end else begin
      enable0 <= sel0_q[STAGES-1];
    end
  end

  //---------------------------------------------------------------------------
  // Branch 1
  //---------------------------------------------------------------------------
  always_ff @(posedge clk1 or negedge rst1_n) begin
    if (!rst1_n) begin
      sel1_q <= '0;
    end else if (!request1) begin
      sel1_q <= '0;
    end else begin
      sel1_q <= {sel1_q[STAGES-2:0], 1'b1};
    end
  end

  always_ff @(negedge clk1 or negedge rst1_n) begin
    if (!rst1_n) begin
      enable1 <= 1'b0;
    end else begin
      enable1 <= sel1_q[STAGES-1];
    end
  end

  //---------------------------------------------------------------------------
  // Output. At most one enable is high at any time, so this is a wired OR of
  // two mutually exclusive gated clocks, never a multiplexer between two live
  // ones.
  //---------------------------------------------------------------------------
  assign clk_out = (clk0 & enable0) | (clk1 & enable1);

  // Status. During the dead time neither branch is enabled and clk_active
  // still reports the outgoing clock, so an integrator polling it sees the
  // switch complete exactly when the new clock starts driving the output.
  assign clk_active = enable1;

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (STAGES < 2) begin
      $fatal(1, {"clk_mux: STAGES must be >= 2 (got %0d); a single flop ",
                 "provides no metastability resolution time"}, STAGES);
    end
  end

  // The safety property of the whole block: the two branches are never enabled
  // together. If this ever fires, the output is a multiplexer between two live
  // clocks and will glitch.
  always @(enable0 or enable1) begin
    if (enable0 === 1'b1 && enable1 === 1'b1) begin
      $error("clk_mux: both branches enabled simultaneously; output will glitch");
    end
  end
`endif

endmodule

`default_nettype wire
