//=============================================================================
// Module      : ram_sdp
// Category    : memory
// Description : Simple dual-port synchronous RAM: one write port and one read
//               port, each in its own clock domain.
//
// This is the most useful memory configuration in practice and the cheapest
// dual-port structure a target can provide. Every FPGA block RAM supports it
// natively, and on an ASIC it maps to a 1R1W macro that is substantially
// smaller than a true dual-port one.
//
// It is also the only dual-port arrangement with a single driving process for
// the array, which matters beyond tidiness: a true dual-port memory is written
// from two clocked processes and is therefore multiply driven, with all the
// collision rules that implies. Here the read port only reads, so there is
// nothing to collide.
//
//   Write / read, different addresses   always safe
//   Write / read, same address          the read returns OLD data
//
// The second rule holds regardless of clock relationship: the read is issued
// from the array before the write in that cycle has landed. Callers that need
// the new data must bypass around the memory, which is what fifo_sync does for
// its first-word-fall-through path.
//
// fifo_sync and fifo_async are both built on this block, which is why it
// exists as an IP in its own right rather than as private storage inside each
// of them.
//
// Parameters
//   DATA_WIDTH    Width of a word. A multiple of 8 if byte enables are used.
//   DEPTH         Number of words. Need not be a power of two.
//   BYTE_ENABLE   Enable per-byte write masking. 0 = off, 1 = on.
//   OUTPUT_REG    Add a registered output stage on the read port. 0/1.
//   INIT_FILE     Optional $readmemh file, loaded in simulation only.
//
// Latency     : 1 read cycle, or 2 with OUTPUT_REG
// Reset       : none. See ram_sp for why a memory array is not reset.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module ram_sdp #(
    parameter int unsigned DATA_WIDTH  = 32,
    parameter int unsigned DEPTH       = 1024,
    parameter int unsigned BYTE_ENABLE = 0,
    parameter int unsigned OUTPUT_REG  = 0,
    // Untyped rather than `parameter string`: Yosys does not accept
    // the string data type in a parameter declaration, and the block
    // must synthesise. A string literal default still reaches
    // $readmemh correctly in simulation.
    parameter       INIT_FILE   = ""
) (
    // Write port
    input  wire                       wr_clk,
    input  wire                       wr_en,
    input  wire  [(DATA_WIDTH/8)-1:0] wr_be,
    input  wire  [$clog2(DEPTH)-1:0]  wr_addr,
    input  wire  [DATA_WIDTH-1:0]     wr_data,

    // Read port
    input  wire                       rd_clk,
    input  wire                       rd_en,
    input  wire  [$clog2(DEPTH)-1:0]  rd_addr,
    output logic [DATA_WIDTH-1:0]     rd_data
);

  localparam int unsigned ADDR_WIDTH = $clog2(DEPTH);
  localparam int unsigned NUM_BYTES  = DATA_WIDTH / 8;

  localparam bit USE_BYTE_ENABLE = (BYTE_ENABLE != 0);
  localparam bit USE_OUTPUT_REG  = (OUTPUT_REG  != 0);

  logic [DATA_WIDTH-1:0] mem [DEPTH];
  logic [DATA_WIDTH-1:0] read_data;

  //---------------------------------------------------------------------------
  // Write port. The only process that drives the array.
  //---------------------------------------------------------------------------
  always_ff @(posedge wr_clk) begin
    if (wr_en) begin
      if (USE_BYTE_ENABLE) begin
        for (int unsigned b = 0; b < NUM_BYTES; b++) begin
          if (wr_be[b]) begin
            mem[wr_addr][b*8 +: 8] <= wr_data[b*8 +: 8];
          end
        end
      end else begin
        mem[wr_addr] <= wr_data;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Read port. Reads only, so the array stays singly driven.
  //---------------------------------------------------------------------------
  always_ff @(posedge rd_clk) begin
    if (rd_en) begin
      read_data <= mem[rd_addr];
    end
  end

  if (USE_OUTPUT_REG) begin : g_output_reg

    always_ff @(posedge rd_clk) begin
      if (rd_en) begin
        rd_data <= read_data;
      end
    end

  end else begin : g_no_output_reg

    assign rd_data = read_data;

  end

  //---------------------------------------------------------------------------
  // Simulation-only initialisation and checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DATA_WIDTH < 1) begin
      $fatal(1, "ram_sdp: DATA_WIDTH must be >= 1 (got %0d)", DATA_WIDTH);
    end
    if (USE_BYTE_ENABLE && (DATA_WIDTH % 8 != 0)) begin
      $fatal(1, {"ram_sdp: DATA_WIDTH must be a multiple of 8 when byte ",
                 "enables are used (got %0d)"}, DATA_WIDTH);
    end
    if (DEPTH < 2) begin
      $fatal(1, "ram_sdp: DEPTH must be >= 2 (got %0d)", DEPTH);
    end
  end

  initial begin : memory_init
    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, mem);
    end
  end

  // When DEPTH is a power of two the address space is exactly the array and
  // every address is valid. The comparison must not be written unconditionally
  // in that case: ADDR_WIDTH'(DEPTH) wraps to zero, making the check
  // permanently false and firing on every legal access.
  logic wr_addr_in_range;
  logic rd_addr_in_range;

  if (2 ** ADDR_WIDTH == DEPTH) begin : g_full_address_space
    assign wr_addr_in_range = 1'b1;
    assign rd_addr_in_range = 1'b1;
  end else begin : g_partial_address_space
    assign wr_addr_in_range = (wr_addr < ADDR_WIDTH'(DEPTH));
    assign rd_addr_in_range = (rd_addr < ADDR_WIDTH'(DEPTH));
  end

  property p_wr_addr_in_range;
    @(posedge wr_clk) wr_en |-> wr_addr_in_range;
  endproperty
  a_wr_addr_in_range : assert property (p_wr_addr_in_range)
    else $error("ram_sdp: write address %0d is outside the %0d-word array",
                wr_addr, DEPTH);

  property p_rd_addr_in_range;
    @(posedge rd_clk) rd_en |-> rd_addr_in_range;
  endproperty
  a_rd_addr_in_range : assert property (p_rd_addr_in_range)
    else $error("ram_sdp: read address %0d is outside the %0d-word array",
                rd_addr, DEPTH);
`endif

endmodule

`default_nettype wire
