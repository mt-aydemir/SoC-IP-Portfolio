//=============================================================================
// Module      : clk_gate
// Category    : clocking
// Description : Glitch-free clock gate.
//
// Gating a clock with a plain AND gate is wrong, and the reason is worth
// stating precisely. The enable is produced by rising-edge logic, so it
// changes shortly after a rising clock edge - in the middle of the clock's
// high phase. ANDing it with the clock therefore chops the current pulse:
//
//   clk     __/‾‾‾\___/‾‾‾\___/‾‾‾\___
//   enable  ______/‾‾‾‾‾‾‾‾‾\_________     changes mid-high-phase
//   naive   ______/‾\___/‾‾‾\_________     runt pulse, then a truncated one
//   AND
//
// A runt pulse is narrower than the flip-flops downstream require and can put
// them into a metastable state, or clock only part of a register bank.
//
// The fix is to hold the enable in a level-sensitive latch that is transparent
// only while the clock is low. Any change on the enable is then absorbed
// during the low phase, and the value presented to the AND gate is already
// stable by the time the clock rises:
//
//   clk       __/‾‾‾\___/‾‾‾\___/‾‾‾\___
//   enable    ______/‾‾‾‾‾‾‾‾‾\_________
//   latched   __________/‾‾‾‾‾‾‾‾‾\_____     updated only while clk is low
//   gated_clk __________/‾‾‾\_____________    whole pulses only
//
// This is exactly the structure of an ASIC library's integrated clock gating
// cell, written so that any synthesiser can infer it and no vendor primitive
// is required.
//
// Parameters
//   (none)
//
// Latency     : the enable takes effect on the next rising edge after the low
//               phase in which it was presented
// Reset       : none; the latch is combinational and the block is stateless
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module clk_gate (
    input  wire  clk,

    // Clock enable, produced by rising-edge logic in the clk domain.
    input  wire  enable,

    // Test enable. Forces the gate open so that scan chains keep clocking
    // during test, independently of the functional enable. Tie low in normal
    // operation; never drive it from functional logic.
    input  wire  test_en,

    output wire  gated_clk
);

  //---------------------------------------------------------------------------
  // Transparent while clk is low, so the sampled value is stable across the
  // whole high phase. always_latch states the intent, which lets the tools
  // check that a latch really is what was meant here - everywhere else in the
  // portfolio an inferred latch is a defect.
  //---------------------------------------------------------------------------
  logic enable_latched;

  always_latch begin
    if (!clk) begin
      enable_latched = enable | test_en;
    end
  end

  assign gated_clk = clk & enable_latched;

  //---------------------------------------------------------------------------
  // Assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  // The gated clock must never rise while the latched enable is low. This is
  // the property the whole block exists to guarantee, and it fails loudly if
  // the latch is ever optimised into a flip-flop or removed.
  always @(posedge gated_clk) begin
    if (enable_latched !== 1'b1) begin
      $error("clk_gate: gated_clk rose while the enable was not latched high");
    end
  end
`endif

endmodule

`default_nettype wire
