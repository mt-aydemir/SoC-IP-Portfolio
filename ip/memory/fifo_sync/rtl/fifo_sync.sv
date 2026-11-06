//=============================================================================
// Module      : fifo_sync
// Category    : memory
// Description : Synchronous FIFO with ready/valid interfaces on both sides,
//               first-word-fall-through, and programmable almost-full and
//               almost-empty flags.
//
// Storage is a ram_sdp instance, so the FIFO costs one block RAM rather than
// DEPTH*DATA_WIDTH flip-flops. That choice brings one problem with it: a
// synchronous RAM has a cycle of read latency, while first-word-fall-through
// means the head word must be visible on the output *before* anyone asks for
// it. The two are reconciled by an output stage of two registers that runs
// ahead of the consumer, prefetching from the RAM whenever it has room.
//
// The output stage is two entries deep rather than one for a specific reason.
// A read issued to the RAM this cycle delivers its word next cycle, and that
// word must have somewhere to go on arrival regardless of what the consumer
// does in between. One entry would mean either stalling the prefetch whenever
// the output is occupied - halving the throughput - or dropping a word.
//
// Write bypass
//   When the RAM is empty and no read is in flight, an incoming word is
//   written straight into the output stage instead of going through the RAM.
//   That takes the empty-FIFO latency from three cycles to one, which matters
//   for a FIFO used as a pipeline stage rather than as a buffer. The bypass is
//   suppressed whenever anything is already in the RAM or in flight, so order
//   is always preserved.
//
// Capacity
//   The FIFO holds DEPTH words in total. Words live either in the RAM or in
//   the output stage, and `level` counts both, so the number reported is the
//   number a consumer can actually still read.
//
// Parameters
//   DATA_WIDTH            Payload width.
//   DEPTH                 Total capacity in words. Need not be a power of two.
//   ALMOST_FULL_LEVEL     almost_full asserts at this level or above.
//   ALMOST_EMPTY_LEVEL    almost_empty asserts at this level or below.
//
// Latency     : 1 cycle when empty (bypass), 3 cycles through the RAM
// Throughput  : one word per cycle sustained, in both directions at once
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module fifo_sync #(
    parameter int unsigned DATA_WIDTH         = 32,
    parameter int unsigned DEPTH              = 16,
    parameter int unsigned ALMOST_FULL_LEVEL  = DEPTH - 1,
    parameter int unsigned ALMOST_EMPTY_LEVEL = 1
) (
    input  wire                        clk,
    input  wire                        rst_n,

    // Write side
    input  wire                        s_valid,
    output logic                       s_ready,
    input  wire  [DATA_WIDTH-1:0]      s_data,

    // Read side
    output logic                       m_valid,
    input  wire                        m_ready,
    output logic [DATA_WIDTH-1:0]      m_data,

    // Status
    output logic [$clog2(DEPTH+1)-1:0] level,
    output logic                       full,
    output logic                       empty,
    output logic                       almost_full,
    output logic                       almost_empty
);

  localparam int unsigned PTR_WIDTH   = (DEPTH <= 1) ? 1 : $clog2(DEPTH);
  localparam int unsigned LEVEL_WIDTH = $clog2(DEPTH + 1);

  // The RAM never holds more than DEPTH words, and the output stage holds at
  // most two, but a word is only ever in one of them.
  localparam int unsigned OUTPUT_DEPTH = 2;

  //---------------------------------------------------------------------------
  // Occupancy tracking
  //---------------------------------------------------------------------------
  logic [LEVEL_WIDTH-1:0] ram_count_q;    // words held in the RAM
  logic                   inflight_q;     // a RAM read lands this cycle
  logic [1:0]             out_count_q;    // words held in the output stage

  logic [PTR_WIDTH-1:0]   wr_ptr_q;
  logic [PTR_WIDTH-1:0]   rd_ptr_q;

  logic                   write_fire;
  logic                   read_fire;
  logic                   bypass;
  logic                   ram_write;
  logic                   ram_read_issue;
  logic                   out_push;

  //---------------------------------------------------------------------------
  // Handshakes
  //---------------------------------------------------------------------------
  assign level   = ram_count_q + LEVEL_WIDTH'(inflight_q) +
                   LEVEL_WIDTH'(out_count_q);
  assign full    = (level == LEVEL_WIDTH'(DEPTH));
  assign empty   = (level == '0);

  assign s_ready = !full;
  assign m_valid = (out_count_q != 2'd0);

  assign write_fire = s_valid && s_ready;
  assign read_fire  = m_valid && m_ready;

  assign almost_full  = (level >= LEVEL_WIDTH'(ALMOST_FULL_LEVEL));
  assign almost_empty = (level <= LEVEL_WIDTH'(ALMOST_EMPTY_LEVEL));

  //---------------------------------------------------------------------------
  // Write bypass.
  //
  // Only legal when nothing is ahead of this word: the RAM must be empty, no
  // read may be in flight, and the output stage must have room. Any of those
  // failing means an earlier word would be overtaken.
  //---------------------------------------------------------------------------
  assign bypass    = write_fire && (ram_count_q == '0) && !inflight_q &&
                     (out_count_q < 2'(OUTPUT_DEPTH));
  assign ram_write = write_fire && !bypass;

  //---------------------------------------------------------------------------
  // Prefetch.
  //
  // Issue a read whenever the RAM has a word and the output stage will have
  // room for it on arrival. The word already in flight is counted, because it
  // will occupy one of the two output slots before this one does.
  //---------------------------------------------------------------------------
  assign ram_read_issue = (ram_count_q != '0) &&
                          ((out_count_q + 2'(inflight_q)) < 2'(OUTPUT_DEPTH));

  // The output stage is pushed either by a word arriving from the RAM or by a
  // bypassed write. The two can never coincide: a bypass requires no read in
  // flight, and a RAM word arriving means one was.
  assign out_push = inflight_q || bypass;

  //---------------------------------------------------------------------------
  // RAM pointers and occupancy
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wr_ptr_q    <= '0;
      rd_ptr_q    <= '0;
      ram_count_q <= '0;
      inflight_q  <= 1'b0;
    end else begin
      if (ram_write) begin
        wr_ptr_q <= (wr_ptr_q == PTR_WIDTH'(DEPTH - 1)) ? '0
                                                        : wr_ptr_q + PTR_WIDTH'(1);
      end
      if (ram_read_issue) begin
        rd_ptr_q <= (rd_ptr_q == PTR_WIDTH'(DEPTH - 1)) ? '0
                                                        : rd_ptr_q + PTR_WIDTH'(1);
      end

      unique case ({ram_write, ram_read_issue})
        2'b10:   ram_count_q <= ram_count_q + LEVEL_WIDTH'(1);
        2'b01:   ram_count_q <= ram_count_q - LEVEL_WIDTH'(1);
        default: ram_count_q <= ram_count_q;
      endcase

      inflight_q <= ram_read_issue;
    end
  end

  //---------------------------------------------------------------------------
  // Storage
  //---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] ram_rdata;

  ram_sdp #(
      .DATA_WIDTH  (DATA_WIDTH),
      .DEPTH       (DEPTH),
      .BYTE_ENABLE (0),
      .OUTPUT_REG  (0)
  ) u_storage (
      .wr_clk  (clk),
      .wr_en   (ram_write),
      .wr_be   ('1),
      .wr_addr (wr_ptr_q),
      .wr_data (s_data),
      .rd_clk  (clk),
      .rd_en   (ram_read_issue),
      .rd_addr (rd_ptr_q),
      .rd_data (ram_rdata)
  );

  //---------------------------------------------------------------------------
  // Output stage: a two-entry register FIFO in front of the consumer.
  //---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] out_data_q [OUTPUT_DEPTH];
  logic [DATA_WIDTH-1:0] push_data;

  assign push_data = bypass ? s_data : ram_rdata;
  assign m_data    = out_data_q[0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_count_q <= 2'd0;
      for (int unsigned i = 0; i < OUTPUT_DEPTH; i++) begin
        out_data_q[i] <= '0;
      end
    end else begin
      unique case ({out_push, read_fire})
        2'b10: begin
          // Push only: the new word goes to the first free slot. The prefetch
          // condition guarantees out_count_q is 0 or 1 here, so its low bit is
          // the slot index.
          out_data_q[out_count_q[0]] <= push_data;
          out_count_q                <= out_count_q + 2'd1;
        end
        2'b01: begin
          // Pop only: shift down.
          out_data_q[0] <= out_data_q[1];
          out_count_q   <= out_count_q - 2'd1;
        end
        2'b11: begin
          // Push and pop together: shift down and land the new word in the
          // slot the shift vacated, so the count is unchanged.
          out_data_q[0] <= out_data_q[1];
          if (out_count_q == 2'd1) begin
            out_data_q[0] <= push_data;
          end else begin
            out_data_q[1] <= push_data;
          end
          out_count_q <= out_count_q;
        end
        default: begin
          out_count_q <= out_count_q;
        end
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks and protocol assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DATA_WIDTH < 1) begin
      $fatal(1, "fifo_sync: DATA_WIDTH must be >= 1 (got %0d)", DATA_WIDTH);
    end
    if (DEPTH < 2) begin
      $fatal(1, "fifo_sync: DEPTH must be >= 2 (got %0d)", DEPTH);
    end
    if (ALMOST_FULL_LEVEL > DEPTH) begin
      $fatal(1, {"fifo_sync: ALMOST_FULL_LEVEL (%0d) exceeds DEPTH (%0d), so ",
                 "the flag could never assert"}, ALMOST_FULL_LEVEL, DEPTH);
    end
  end

  // Overflow and underflow are caller errors, and both are silent corruption
  // if they are not caught here.
  property p_no_overflow;
    @(posedge clk) disable iff (!rst_n) (s_valid && full) |-> !s_ready;
  endproperty
  a_no_overflow : assert property (p_no_overflow)
    else $error("fifo_sync: write accepted while full");

  // A word on offer is a word held. The reverse does not hold: while the RAM
  // read is in flight the FIFO has a level and nothing on offer yet.
  property p_no_underflow;
    @(posedge clk) disable iff (!rst_n) m_valid |-> !empty;
  endproperty
  a_no_underflow : assert property (p_no_underflow)
    else $error("fifo_sync: word offered while empty");

  // The output stage must never be pushed when it is already full.
  property p_output_no_overflow;
    @(posedge clk) disable iff (!rst_n)
      (out_push && !read_fire) |-> (out_count_q < 2'(OUTPUT_DEPTH));
  endproperty
  a_output_no_overflow : assert property (p_output_no_overflow)
    else $error("fifo_sync: prefetch overran the output stage");

  // Level must never exceed the advertised capacity.
  property p_level_bounded;
    @(posedge clk) disable iff (!rst_n) (level <= LEVEL_WIDTH'(DEPTH));
  endproperty
  a_level_bounded : assert property (p_level_bounded)
    else $error("fifo_sync: level %0d exceeds DEPTH %0d", level, DEPTH);

  // The source must hold its payload while stalled.
  property p_payload_stable;
    @(posedge clk) disable iff (!rst_n)
      (s_valid && !s_ready) |=> $stable(s_data);
  endproperty
  a_payload_stable : assert property (p_payload_stable)
    else $error("fifo_sync: s_data changed while the write was stalled");
`endif

endmodule

`default_nettype wire
