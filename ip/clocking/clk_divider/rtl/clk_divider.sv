//=============================================================================
// Module      : clk_divider
// Category    : clocking
// Description : Integer clock divider producing both a divided clock and the
//               equivalent clock enable.
//
// Two outputs are provided because they solve the same problem in different
// ways, and the right choice depends on the target.
//
//   clk_en   A single-cycle enable pulse in the *source* clock domain, one
//            pulse every DIVISOR cycles. This is the preferred output. The
//            whole design stays in one clock domain, static timing analysis
//            sees one clock, and no clock tree resource is consumed. Use it
//            unless something genuinely needs a slower clock edge.
//
//   clk_out  A real divided clock, 50% duty cycle for every DIVISOR >= 2,
//            odd ratios included. Use it only when a slower clock is
//            unavoidable - driving an external device, or feeding a block
//            that has no enable input. It is a generated clock and must be
//            declared as such in the SDC; see scripts/clk_divider.sdc.
//
// A 50% duty cycle at an odd DIVISOR is not achievable from the rising edge
// alone: the high and low phases would have to differ by one source period.
// The odd case therefore combines a rising-edge-generated phase with a
// falling-edge-generated one, which shifts the second by half a period and
// makes the two halves equal. That costs one negative-edge flip-flop, so the
// even case, which does not need it, does not pay for it.
//
// Parameters
//   DIVISOR  Division ratio. 1 passes the clock through unchanged.
//
// Latency     : clk_en asserts on the last source cycle of each period
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module clk_divider #(
    parameter int unsigned DIVISOR = 2
) (
    input  wire  clk,
    input  wire  rst_n,

    // Synchronous enable. Deasserting it stops the divider and parks both
    // outputs in their reset state; it does not merely pause the counter.
    input  wire  enable,

    // One source-clock cycle wide, once every DIVISOR source cycles.
    output logic clk_en,

    // Divided clock, 50% duty for DIVISOR >= 2.
    output logic clk_out
);

  localparam int unsigned CNT_WIDTH = (DIVISOR <= 2) ? 1 : $clog2(DIVISOR);

  //---------------------------------------------------------------------------
  // Pass-through case. A divider by one is a wire, and building a counter for
  // it would cost area and add a clock tree for no reason.
  //---------------------------------------------------------------------------
  if (DIVISOR == 1) begin : g_passthrough

    // clk_en is qualified with reset so that the enable behaves identically at
    // every DIVISOR: no enable pulses are produced while the block is in
    // reset. The clock itself is passed through untouched - gating a clock
    // with a reset would defeat the reset synchronisers downstream, which need
    // edges in order to release.
    assign clk_en  = enable & rst_n;
    assign clk_out = clk;

  end else begin : g_divide

    //-------------------------------------------------------------------------
    // Rising-edge counter. Shared by both outputs and by both parity cases.
    //-------------------------------------------------------------------------
    logic [CNT_WIDTH-1:0] count_q;
    logic                 count_wrap;

    assign count_wrap = (count_q == CNT_WIDTH'(DIVISOR - 1));

    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        count_q <= '0;
      end else if (!enable) begin
        count_q <= '0;
      end else if (count_wrap) begin
        count_q <= '0;
      end else begin
        count_q <= count_q + CNT_WIDTH'(1);
      end
    end

    // The enable pulse marks the final source cycle of each divided period, so
    // a register enabled by it updates on the same edge that clk_out rises.
    assign clk_en = enable && count_wrap;

    if (DIVISOR % 2 == 0) begin : g_even

      //-----------------------------------------------------------------------
      // Even ratio: the two halves are equal by construction, so a single
      // rising-edge flip-flop toggling at the half-way point is exact.
      //-----------------------------------------------------------------------
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          clk_out <= 1'b0;
        end else if (!enable) begin
          clk_out <= 1'b0;
        end else if (count_wrap || (count_q == CNT_WIDTH'(DIVISOR / 2 - 1))) begin
          clk_out <= ~clk_out;
        end
      end

    end else begin : g_odd

      //-----------------------------------------------------------------------
      // Odd ratio. The rising-edge phase is high for (DIVISOR+1)/2 source
      // cycles and the falling-edge phase is the same waveform delayed by half
      // a source period. ANDing them removes exactly half a source period from
      // the high time, giving (DIVISOR+1)/2 - 1/2 = DIVISOR/2 - a true 50%
      // duty cycle.
      //-----------------------------------------------------------------------
      localparam int unsigned HIGH_CYCLES = (DIVISOR + 1) / 2;

      logic phase_rise_q;
      logic phase_fall_q;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          phase_rise_q <= 1'b0;
        end else if (!enable) begin
          phase_rise_q <= 1'b0;
        end else if (count_wrap) begin
          phase_rise_q <= 1'b1;
        end else if (count_q == CNT_WIDTH'(HIGH_CYCLES - 1)) begin
          phase_rise_q <= 1'b0;
        end
      end

      always_ff @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
          phase_fall_q <= 1'b0;
        end else begin
          phase_fall_q <= phase_rise_q;
        end
      end

      assign clk_out = phase_rise_q & phase_fall_q;

    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DIVISOR < 1) begin
      $fatal(1, "clk_divider: DIVISOR must be >= 1 (got %0d)", DIVISOR);
    end
  end
`endif

endmodule

`default_nettype wire
