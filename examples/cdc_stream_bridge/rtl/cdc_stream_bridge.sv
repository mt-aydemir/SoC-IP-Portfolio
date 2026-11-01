//=============================================================================
// Module      : cdc_stream_bridge
// Category    : examples
// Description : Carries a ready/valid stream between two unrelated clock
//               domains, from one raw asynchronous reset - built from
//               `cdc_reset_sync` and `fifo_async`.
//
// An integration example rather than a catalogue IP. Clock domain crossing is
// the most common source of bugs that simulation does not catch, and the bugs
// are almost never inside the synchroniser - they are in how it is wired. This
// example is the wiring done right, kept compiling and verified as the blocks
// it uses evolve.
//
// WHAT IT GETS RIGHT
//   One reset, synchronised into each domain separately
//       The raw reset is asynchronous to both clocks. Each domain gets its own
//       cdc_reset_sync, so each sees a reset that asserts immediately and
//       releases synchronously to its own clock. Using one domain's
//       synchronised reset in the other is the classic mistake: its release
//       is a timing path between unrelated clocks, which no constraint can
//       make safe.
//
//   Both sides of the FIFO reset together
//       The FIFO's pointers live in both domains. Resetting one side alone
//       leaves the other with a pointer the first no longer agrees with, and
//       the FIFO reports words that were never written. Driving both resets
//       from the same raw source guarantees they are asserted together.
//
//   Nothing crosses except through the FIFO
//       No signal of either domain is used in the other. The only crossings
//       are the Gray-coded pointers inside fifo_async, which is the only kind
//       of multi-bit crossing that is safe.
//
// Parameters
//   DATA_WIDTH   Payload width.
//   DEPTH        FIFO depth; a power of two, >= 4. Sets how much rate
//                mismatch the bridge can absorb.
//   SYNC_STAGES  Synchroniser depth, used for the resets and the pointers.
//
// Latency     : SYNC_STAGES + 2 destination-clock cycles
// Throughput  : the slower of the two sides
// Reset       : one raw asynchronous reset, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module cdc_stream_bridge #(
    parameter int unsigned DATA_WIDTH  = 32,
    parameter int unsigned DEPTH       = 16,
    parameter int unsigned SYNC_STAGES = 2
) (
    // The one reset. Raw and asynchronous: no relationship to either clock.
    input  wire                   arst_n,

    // Source domain
    input  wire                   src_clk,
    input  wire                   s_valid,
    output logic                  s_ready,
    input  wire  [DATA_WIDTH-1:0] s_data,

    // Destination domain
    input  wire                   dst_clk,
    output logic                  m_valid,
    input  wire                   m_ready,
    output logic [DATA_WIDTH-1:0] m_data
);

  //---------------------------------------------------------------------------
  // One synchroniser per domain, fed from the same raw reset.
  //---------------------------------------------------------------------------
  logic src_rst_n;
  logic dst_rst_n;

  cdc_reset_sync #(
      .STAGES (SYNC_STAGES)
  ) u_src_reset (
      .clk       (src_clk),
      .arst_n_in (arst_n),
      .rst_n_out (src_rst_n)
  );

  cdc_reset_sync #(
      .STAGES (SYNC_STAGES)
  ) u_dst_reset (
      .clk       (dst_clk),
      .arst_n_in (arst_n),
      .rst_n_out (dst_rst_n)
  );

  //---------------------------------------------------------------------------
  // The crossing itself. The level and flag outputs are left unconnected: a
  // bridge that only moves data has no use for them, and an integrator who
  // does should take them from fifo_async directly.
  //---------------------------------------------------------------------------
  // Unconnected outputs are deliberate, see above.
  /* verilator lint_off PINCONNECTEMPTY */
  fifo_async #(
      .DATA_WIDTH  (DATA_WIDTH),
      .DEPTH       (DEPTH),
      .SYNC_STAGES (SYNC_STAGES)
  ) u_fifo (
      .wr_clk          (src_clk),
      .wr_rst_n        (src_rst_n),
      .s_valid         (s_valid),
      .s_ready         (s_ready),
      .s_data          (s_data),
      .wr_level        (),
      .wr_full         (),
      .wr_almost_full  (),

      .rd_clk          (dst_clk),
      .rd_rst_n        (dst_rst_n),
      .m_valid         (m_valid),
      .m_ready         (m_ready),
      .m_data          (m_data),
      .rd_level        (),
      .rd_empty        (),
      .rd_almost_empty ()
  );
  /* verilator lint_on PINCONNECTEMPTY */

endmodule

`default_nettype wire
