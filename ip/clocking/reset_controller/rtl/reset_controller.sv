//=============================================================================
// Module      : reset_controller
// Category    : clocking
// Description : Combines the reset sources of one clock domain and releases a
//               staged reset tree in a defined order.
//
// A real SoC does not have one reset. It has a power-on reset, a software
// reset written by the CPU, a watchdog timeout and usually a debug reset, and
// the blocks they reset must come out of reset in a defined order. A bus
// interconnect that starts before its slaves will forward transactions into
// blocks that are still resetting; a DMA engine that starts before the
// interconnect will issue reads that go nowhere.
//
// This block provides:
//
//   * OR-combining of an asynchronous source and a synchronous request, so
//     that combinational glitches never reach the reset tree;
//   * a guaranteed minimum assertion time, so a one-cycle software request
//     still produces a reset long enough for every block to see it;
//   * synchronous release, via the same asynchronous-assert / synchronous-
//     release structure as cdc_reset_sync;
//   * NUM_STAGES staged outputs released in ascending index order with
//     STAGE_DELAY cycles between them.
//
// Assign stage 0 to the most fundamental blocks - clocking, memory
// controllers - and the highest stage to the masters that drive traffic. On
// assertion all stages assert together and immediately; only the release is
// sequenced. Bringing a system down in stages would leave transactions in
// flight with no one to answer them.
//
// Parameters
//   NUM_STAGES         Number of staged reset outputs.
//   STAGE_DELAY        Clock cycles between consecutive stage releases.
//   MIN_ASSERT_CYCLES  Minimum assertion time in clock cycles.
//   SYNC_STAGES        Synchroniser depth for the release edge.
//
// Latency     : release of stage n is MIN_ASSERT_CYCLES + n*STAGE_DELAY
//               cycles after the sources clear
// Reset       : this block *is* the reset path
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module reset_controller #(
    parameter int unsigned NUM_STAGES        = 4,
    parameter int unsigned STAGE_DELAY       = 4,
    parameter int unsigned MIN_ASSERT_CYCLES = 16,
    parameter int unsigned SYNC_STAGES       = 3
) (
    input  wire                    clk,

    // Asynchronous reset sources, active low. Combine power-on reset and any
    // external reset pin here, outside the block.
    input  wire                    arst_n_in,

    // Synchronous reset request, active high. A single-cycle pulse is enough;
    // the block stretches it to MIN_ASSERT_CYCLES.
    input  wire                    sw_reset,

    // Staged resets, active low. Index 0 releases first.
    output logic [NUM_STAGES-1:0]  rst_n_out,

    // High while any stage is still asserted.
    output logic                   reset_active
);

  // Worst case wait: the minimum assertion time plus every stage delay.
  localparam int unsigned MAX_COUNT =
      MIN_ASSERT_CYCLES + (NUM_STAGES * STAGE_DELAY) + 1;
  localparam int unsigned CNT_WIDTH = (MAX_COUNT <= 2) ? 1 : $clog2(MAX_COUNT + 1);

  //---------------------------------------------------------------------------
  // Stage 1: synchronise the release of the asynchronous source.
  //
  // Reused rather than reimplemented: the asynchronous-assert /
  // synchronous-release structure is exactly cdc_reset_sync.
  //---------------------------------------------------------------------------
  logic core_rst_n;

  cdc_reset_sync #(
      .STAGES (SYNC_STAGES)
  ) u_sync (
      .clk       (clk),
      .arst_n_in (arst_n_in),
      .rst_n_out (core_rst_n)
  );

  //---------------------------------------------------------------------------
  // Stage 2: stretch a software request to the minimum assertion time.
  //
  // sw_reset may be a single cycle wide. Restarting the counter whenever it is
  // high means the assertion always lasts at least MIN_ASSERT_CYCLES beyond
  // the last request, however short the request itself was.
  //---------------------------------------------------------------------------
  logic [CNT_WIDTH-1:0] count_q;
  logic                 counting;

  assign counting = (count_q != CNT_WIDTH'(MAX_COUNT - 1));

  always_ff @(posedge clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      count_q <= '0;
    end else if (sw_reset) begin
      count_q <= '0;
    end else if (counting) begin
      count_q <= count_q + CNT_WIDTH'(1);
    end
  end

  //---------------------------------------------------------------------------
  // Stage 3: sequenced release.
  //
  // Stage n releases once the counter has passed the minimum assertion time
  // plus n stage delays. Registering the comparison keeps the reset tree
  // driven by flip-flops rather than by a wide comparator, which matters on a
  // net that fans out across the whole design.
  //---------------------------------------------------------------------------
  for (genvar s = 0; s < int'(NUM_STAGES); s++) begin : g_stage
    localparam int unsigned RELEASE_AT = MIN_ASSERT_CYCLES + (s * STAGE_DELAY);

    always_ff @(posedge clk or negedge core_rst_n) begin
      if (!core_rst_n) begin
        rst_n_out[s] <= 1'b0;
      end else if (sw_reset) begin
        rst_n_out[s] <= 1'b0;
      end else begin
        rst_n_out[s] <= (count_q >= CNT_WIDTH'(RELEASE_AT));
      end
    end
  end

  always_ff @(posedge clk or negedge core_rst_n) begin
    if (!core_rst_n) begin
      reset_active <= 1'b1;
    end else begin
      reset_active <= sw_reset ||
                      (count_q < CNT_WIDTH'(MIN_ASSERT_CYCLES +
                                            ((NUM_STAGES - 1) * STAGE_DELAY)));
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (NUM_STAGES < 1) begin
      $fatal(1, "reset_controller: NUM_STAGES must be >= 1 (got %0d)", NUM_STAGES);
    end
    if (MIN_ASSERT_CYCLES < 1) begin
      $fatal(1, {"reset_controller: MIN_ASSERT_CYCLES must be >= 1 (got %0d); ",
                 "a zero-length reset would not be seen by every block"},
             MIN_ASSERT_CYCLES);
    end
    if (SYNC_STAGES < 2) begin
      $fatal(1, "reset_controller: SYNC_STAGES must be >= 2 (got %0d)", SYNC_STAGES);
    end
  end

  // Stages must release in ascending order: a higher stage may never be
  // released while a lower one is still asserted. Checked pairwise so the
  // property is valid at every NUM_STAGES, including 1.
  for (genvar s = 1; s < int'(NUM_STAGES); s++) begin : g_order_check
    property p_release_order;
      @(posedge clk) disable iff (!core_rst_n)
        rst_n_out[s] |-> rst_n_out[s-1];
    endproperty
    a_release_order : assert property (p_release_order)
      else $error("reset_controller: stage %0d released before stage %0d", s, s - 1);
  end
`endif

endmodule

`default_nettype wire
