//=============================================================================
// Module      : fifo_async
// Category    : memory
// Description : Asynchronous FIFO. Moves a data stream between two clock
//               domains of arbitrary, unrelated frequencies.
//
// This is the block to use for continuous traffic across a clock domain
// boundary. cdc_handshake pays a full round trip per word and is the right
// choice for occasional transfers; this one sustains one word per cycle in
// each domain.
//
// HOW THE POINTERS CROSS
//
// The only things that cross the boundary are the two pointers, and they cross
// Gray coded. A binary counter stepping from 0111 to 1000 changes every bit at
// once, so a synchroniser sampling it mid-transition can produce any of the
// sixteen values - including values the counter never held. Gray code changes
// exactly one bit per increment, so a sample taken during a transition yields
// either the old value or the new one. Never anything else.
//
// That property is what makes the comparison safe rather than merely usually
// correct. A stale pointer makes the FIFO look emptier than it is on the write
// side, and fuller than it is on the read side - conservative in both
// directions, which is the only acceptable direction to be wrong in.
//
// The pointers are one bit wider than the address they carry. The extra bit
// distinguishes full from empty: both conditions have equal address bits, and
// they differ only in whether the pointers have wrapped a different number of
// times.
//
// DEPTH must be a power of two. Gray coding relies on the counter wrapping
// exactly at the top of its range; a counter that wraps early produces two
// adjacent codes differing in more than one bit, and the whole guarantee
// collapses.
//
// SHOW-AHEAD OUTPUT
//
// Storage is a ram_sdp, so a read takes a cycle. First-word-fall-through
// requires the head word to be visible before it is asked for, so the read
// side runs a two-entry prefetch stage ahead of the consumer, exactly as
// fifo_sync does. The stage holds up to two words beyond the DEPTH stored in
// the RAM, so the block's total capacity is DEPTH + 2; `wr_full` refers to the
// RAM, which is what the writer needs to know.
//
// Parameters
//   DATA_WIDTH          Payload width.
//   DEPTH               RAM depth in words. Must be a power of two, >= 4.
//   SYNC_STAGES         Synchroniser depth for the pointer crossings.
//   ALMOST_FULL_LEVEL   wr_almost_full asserts at this RAM level or above.
//   ALMOST_EMPTY_LEVEL  rd_almost_empty asserts at this RAM level or below.
//
// Latency     : SYNC_STAGES + 2 read-clock cycles from write to m_valid
// Throughput  : one word per clock in each domain, sustained
// Reset       : asynchronous assertion, synchronous release, active low, one
//               reset per domain
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module fifo_async #(
    parameter int unsigned DATA_WIDTH         = 32,
    parameter int unsigned DEPTH              = 16,
    parameter int unsigned SYNC_STAGES        = 2,
    parameter int unsigned ALMOST_FULL_LEVEL  = DEPTH - 2,
    parameter int unsigned ALMOST_EMPTY_LEVEL = 1
) (
    // Write domain
    input  wire                        wr_clk,
    input  wire                        wr_rst_n,
    input  wire                        s_valid,
    output logic                       s_ready,
    input  wire  [DATA_WIDTH-1:0]      s_data,
    output logic [$clog2(DEPTH+1)-1:0] wr_level,
    output logic                       wr_full,
    output logic                       wr_almost_full,

    // Read domain
    input  wire                        rd_clk,
    input  wire                        rd_rst_n,
    output logic                       m_valid,
    input  wire                        m_ready,
    output logic [DATA_WIDTH-1:0]      m_data,
    output logic [$clog2(DEPTH+1)-1:0] rd_level,
    output logic                       rd_empty,
    output logic                       rd_almost_empty
);

  localparam int unsigned ADDR_WIDTH   = $clog2(DEPTH);
  localparam int unsigned PTR_WIDTH    = ADDR_WIDTH + 1;   // one guard bit
  localparam int unsigned LEVEL_WIDTH  = $clog2(DEPTH + 1);
  localparam int unsigned OUTPUT_DEPTH = 2;

  //---------------------------------------------------------------------------
  // Gray code helpers.
  //
  // The reverse conversion is an XOR reduction of the bits above and including
  // each position; written as a loop it is a prefix XOR chain, which is what
  // synthesis produces either way.
  //---------------------------------------------------------------------------
  // The result is assigned to the function name: Yosys does not accept
  // `return` in a function, though it takes the typed, automatic declaration.
  function automatic logic [PTR_WIDTH-1:0] bin_to_gray(input logic [PTR_WIDTH-1:0] value);
    bin_to_gray = value ^ (value >> 1);
  endfunction

  function automatic logic [PTR_WIDTH-1:0] gray_to_bin(input logic [PTR_WIDTH-1:0] value);
    gray_to_bin[PTR_WIDTH-1] = value[PTR_WIDTH-1];
    for (int i = PTR_WIDTH - 1; i > 0; i--) begin
      gray_to_bin[i-1] = gray_to_bin[i] ^ value[i-1];
    end
  endfunction

  //---------------------------------------------------------------------------
  // Write domain
  //---------------------------------------------------------------------------
  logic [PTR_WIDTH-1:0] wr_ptr_bin_q;
  logic [PTR_WIDTH-1:0] wr_ptr_gray_q;
  logic [PTR_WIDTH-1:0] wr_ptr_bin_next;
  logic [PTR_WIDTH-1:0] rd_ptr_gray_in_wr;
  logic [PTR_WIDTH-1:0] rd_ptr_bin_in_wr;

  logic                 write_fire;

  assign write_fire      = s_valid && s_ready;
  assign wr_ptr_bin_next = wr_ptr_bin_q + PTR_WIDTH'(write_fire);

  always_ff @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
      wr_ptr_bin_q  <= '0;
      wr_ptr_gray_q <= '0;
    end else begin
      wr_ptr_bin_q  <= wr_ptr_bin_next;
      wr_ptr_gray_q <= bin_to_gray(wr_ptr_bin_next);
    end
  end

  cdc_sync_2ff #(
      .WIDTH       (PTR_WIDTH),
      .STAGES      (SYNC_STAGES),
      .RESET_VALUE ('0)
  ) u_sync_rd_ptr (
      .clk     (wr_clk),
      .rst_n   (wr_rst_n),
      .d_async (rd_ptr_gray_q),
      .q_sync  (rd_ptr_gray_in_wr)
  );

  assign rd_ptr_bin_in_wr = gray_to_bin(rd_ptr_gray_in_wr);

  // Full: the pointers address the same word but have wrapped a different
  // number of times, which in Gray code means the top two bits are inverted
  // and the rest match.
  assign wr_full = (wr_ptr_gray_q ==
                    {~rd_ptr_gray_in_wr[PTR_WIDTH-1:PTR_WIDTH-2],
                      rd_ptr_gray_in_wr[PTR_WIDTH-3:0]});

  assign s_ready = !wr_full;

  // Conservative by construction: rd_ptr_bin_in_wr may be stale, which can
  // only make the level look larger than it is.
  assign wr_level       = LEVEL_WIDTH'(wr_ptr_bin_q - rd_ptr_bin_in_wr);
  assign wr_almost_full = (wr_level >= LEVEL_WIDTH'(ALMOST_FULL_LEVEL));

  //---------------------------------------------------------------------------
  // Read domain
  //---------------------------------------------------------------------------
  logic [PTR_WIDTH-1:0] rd_ptr_bin_q;
  logic [PTR_WIDTH-1:0] rd_ptr_gray_q;
  logic [PTR_WIDTH-1:0] rd_ptr_bin_next;
  logic [PTR_WIDTH-1:0] wr_ptr_gray_in_rd;
  logic [PTR_WIDTH-1:0] wr_ptr_bin_in_rd;

  logic                 ram_empty;
  logic                 read_issue;
  logic                 inflight_q;
  logic [1:0]           out_count_q;
  logic                 read_fire;

  cdc_sync_2ff #(
      .WIDTH       (PTR_WIDTH),
      .STAGES      (SYNC_STAGES),
      .RESET_VALUE ('0)
  ) u_sync_wr_ptr (
      .clk     (rd_clk),
      .rst_n   (rd_rst_n),
      .d_async (wr_ptr_gray_q),
      .q_sync  (wr_ptr_gray_in_rd)
  );

  assign wr_ptr_bin_in_rd = gray_to_bin(wr_ptr_gray_in_rd);

  // Empty: the pointers match exactly, wrap bit included.
  assign ram_empty = (rd_ptr_gray_q == wr_ptr_gray_in_rd);

  // Prefetch whenever the RAM has a word and the output stage will have room
  // for it on arrival.
  assign read_issue = !ram_empty &&
                      ((out_count_q + 2'(inflight_q)) < 2'(OUTPUT_DEPTH));

  assign rd_ptr_bin_next = rd_ptr_bin_q + PTR_WIDTH'(read_issue);

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      rd_ptr_bin_q  <= '0;
      rd_ptr_gray_q <= '0;
      inflight_q    <= 1'b0;
    end else begin
      rd_ptr_bin_q  <= rd_ptr_bin_next;
      rd_ptr_gray_q <= bin_to_gray(rd_ptr_bin_next);
      inflight_q    <= read_issue;
    end
  end

  assign rd_level        = LEVEL_WIDTH'(wr_ptr_bin_in_rd - rd_ptr_bin_q);
  assign rd_almost_empty = (rd_level <= LEVEL_WIDTH'(ALMOST_EMPTY_LEVEL));

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
      .wr_clk  (wr_clk),
      .wr_en   (write_fire),
      .wr_be   ('1),
      .wr_addr (wr_ptr_bin_q[ADDR_WIDTH-1:0]),
      .wr_data (s_data),
      .rd_clk  (rd_clk),
      .rd_en   (read_issue),
      .rd_addr (rd_ptr_bin_q[ADDR_WIDTH-1:0]),
      .rd_data (ram_rdata)
  );

  //---------------------------------------------------------------------------
  // Show-ahead output stage, in the read domain
  //---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] out_data_q [OUTPUT_DEPTH];

  assign m_valid   = (out_count_q != 2'd0);
  assign m_data    = out_data_q[0];
  assign read_fire = m_valid && m_ready;
  assign rd_empty  = !m_valid;

  always_ff @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
      out_count_q <= 2'd0;
      for (int unsigned i = 0; i < OUTPUT_DEPTH; i++) begin
        out_data_q[i] <= '0;
      end
    end else begin
      unique case ({inflight_q, read_fire})
        2'b10: begin
          out_data_q[out_count_q[0]] <= ram_rdata;
          out_count_q                <= out_count_q + 2'd1;
        end
        2'b01: begin
          out_data_q[0] <= out_data_q[1];
          out_count_q   <= out_count_q - 2'd1;
        end
        2'b11: begin
          out_data_q[0] <= out_data_q[1];
          if (out_count_q == 2'd1) begin
            out_data_q[0] <= ram_rdata;
          end else begin
            out_data_q[1] <= ram_rdata;
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
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DATA_WIDTH < 1) begin
      $fatal(1, "fifo_async: DATA_WIDTH must be >= 1 (got %0d)", DATA_WIDTH);
    end
    if (DEPTH < 4) begin
      $fatal(1, "fifo_async: DEPTH must be >= 4 (got %0d)", DEPTH);
    end
    if ((DEPTH & (DEPTH - 1)) != 0) begin
      $fatal(1, {"fifo_async: DEPTH must be a power of two (got %0d); Gray ",
                 "coding requires the pointer to wrap at the top of its range"},
             DEPTH);
    end
    if (SYNC_STAGES < 2) begin
      $fatal(1, "fifo_async: SYNC_STAGES must be >= 2 (got %0d)", SYNC_STAGES);
    end
  end

  property p_no_overflow;
    @(posedge wr_clk) disable iff (!wr_rst_n) (s_valid && wr_full) |-> !s_ready;
  endproperty
  a_no_overflow : assert property (p_no_overflow)
    else $error("fifo_async: write accepted while full");

  property p_output_no_overflow;
    @(posedge rd_clk) disable iff (!rd_rst_n)
      (inflight_q && !read_fire) |-> (out_count_q < 2'(OUTPUT_DEPTH));
  endproperty
  a_output_no_overflow : assert property (p_output_no_overflow)
    else $error("fifo_async: prefetch overran the output stage");

  property p_level_bounded;
    @(posedge wr_clk) disable iff (!wr_rst_n) (wr_level <= LEVEL_WIDTH'(DEPTH));
  endproperty
  a_level_bounded : assert property (p_level_bounded)
    else $error("fifo_async: wr_level %0d exceeds DEPTH %0d", wr_level, DEPTH);

  property p_payload_stable;
    @(posedge wr_clk) disable iff (!wr_rst_n)
      (s_valid && !s_ready) |=> $stable(s_data);
  endproperty
  a_payload_stable : assert property (p_payload_stable)
    else $error("fifo_async: s_data changed while the write was stalled");
`endif

endmodule

`default_nettype wire
