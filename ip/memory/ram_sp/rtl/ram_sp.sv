//=============================================================================
// Module      : ram_sp
// Category    : memory
// Description : Single-port synchronous RAM with byte enables and an optional
//               output register.
//
// Written as an inferable array with no vendor primitive and no ram_style
// attribute, so the same source maps onto FPGA block RAM, FPGA distributed
// RAM or an ASIC macro according to the target tool's own heuristics. Guiding
// that choice belongs in the project's constraints, not in this file.
//
// The structure is the one every synthesiser recognises as a synchronous RAM:
// a single clocked process containing the write, and a registered read from
// the same array. Anything more elaborate - a read in a separate process, an
// asynchronous read, a reset on the array - prevents inference and silently
// produces a wall of flip-flops instead.
//
// Read latency
//   OUTPUT_REG = 0   one cycle: data is valid on the cycle after the address
//   OUTPUT_REG = 1   two cycles, with a registered output
//
// The extra register costs a cycle and buys timing closure. On an FPGA it maps
// into the block RAM's own output register and costs no fabric at all, which
// usually makes it free in area and a large win in Fmax.
//
// Read-during-write
//   Reading and writing the same address in the same cycle returns the OLD
//   contents ("read first"). This is the behaviour every target can implement;
//   write-first is not universally available and is deliberately not offered,
//   because a parameter that silently changes meaning between targets is worse
//   than no parameter.
//
// Parameters
//   DATA_WIDTH    Width of a word. Must be a multiple of 8 if byte enables
//                 are used.
//   DEPTH         Number of words. Need not be a power of two.
//   BYTE_ENABLE   Enable per-byte write masking.
//   OUTPUT_REG    Add a registered output stage.
//   INIT_FILE     Optional $readmemh file, loaded in simulation only.
//
// Reset       : none. A memory has no reset, and neither does its output
//               register: a reset on the array would force every bit into
//               fabric flip-flops, and resetting only the output register
//               would be a false promise, since the value it holds is
//               meaningless until a read has been issued anyway. Contents and
//               rdata are undefined until written and read respectively,
//               exactly as for any real memory.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module ram_sp #(
    parameter int unsigned DATA_WIDTH  = 32,
    parameter int unsigned DEPTH       = 1024,
    // Boolean parameters are int unsigned, not bit, throughout the portfolio.
    // A one-bit parameter overridden from a tool command line receives a
    // 32-bit literal and produces a width-truncation warning on every build,
    // which the zero-warning lint policy would then fail. 0 = off, 1 = on.
    parameter int unsigned BYTE_ENABLE = 1,
    parameter int unsigned OUTPUT_REG  = 0,
    // Untyped rather than `parameter string`: Yosys does not accept
    // the string data type in a parameter declaration, and the block
    // must synthesise. A string literal default still reaches
    // $readmemh correctly in simulation.
    parameter       INIT_FILE   = ""
) (
    input  wire                          clk,

    input  wire                          en,        // access enable
    input  wire                          we,        // write when high
    input  wire  [(DATA_WIDTH/8)-1:0]    be,        // byte enables
    input  wire  [$clog2(DEPTH)-1:0]     addr,
    input  wire  [DATA_WIDTH-1:0]        wdata,
    output logic [DATA_WIDTH-1:0]        rdata
);

  localparam int unsigned ADDR_WIDTH = $clog2(DEPTH);
  localparam int unsigned NUM_BYTES  = DATA_WIDTH / 8;

  // Narrow the integer-typed boolean parameters to one bit once, here, rather
  // than relying on an implicit conversion at each use. Using a 32-bit value
  // directly as a condition warns on every build.
  localparam bit USE_BYTE_ENABLE = (BYTE_ENABLE != 0);
  localparam bit USE_OUTPUT_REG  = (OUTPUT_REG  != 0);

  //---------------------------------------------------------------------------
  // Storage.
  //
  // Deliberately not reset. A reset on a memory array forces every bit into
  // fabric flip-flops - a 1024x32 array becomes 32768 registers instead of one
  // block RAM. Memory contents are undefined until written, which is what
  // every real memory does, and the documentation says so.
  //---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] mem [DEPTH];

  logic [DATA_WIDTH-1:0] read_data;

  always_ff @(posedge clk) begin
    if (en) begin
      if (we) begin
        if (USE_BYTE_ENABLE) begin
          for (int unsigned b = 0; b < NUM_BYTES; b++) begin
            if (be[b]) begin
              mem[addr][b*8 +: 8] <= wdata[b*8 +: 8];
            end
          end
        end else begin
          mem[addr] <= wdata;
        end
      end
      // Read first: the read is issued from the array before the write in the
      // same cycle has landed, so a coincident read returns the old contents.
      read_data <= mem[addr];
    end
  end

  //---------------------------------------------------------------------------
  // Optional output register.
  //---------------------------------------------------------------------------
  if (USE_OUTPUT_REG) begin : g_output_reg

    // Enabled by en so that rdata holds its value when the memory is idle,
    // which is what a block RAM's output register does and what a consumer
    // that stalls expects.
    always_ff @(posedge clk) begin
      if (en) begin
        rdata <= read_data;
      end
    end

  end else begin : g_no_output_reg

    assign rdata = read_data;

  end

  //---------------------------------------------------------------------------
  // Simulation-only initialisation and checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DATA_WIDTH < 8) begin
      $fatal(1, "ram_sp: DATA_WIDTH must be >= 8 (got %0d)", DATA_WIDTH);
    end
    if (USE_BYTE_ENABLE && (DATA_WIDTH % 8 != 0)) begin
      $fatal(1, {"ram_sp: DATA_WIDTH must be a multiple of 8 when byte ",
                 "enables are used (got %0d)"}, DATA_WIDTH);
    end
    if (DEPTH < 2) begin
      $fatal(1, "ram_sp: DEPTH must be >= 2 (got %0d)", DEPTH);
    end
  end

  initial begin : memory_init
    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, mem);
    end
  end

  // Accessing outside the array is a caller error. With a non-power-of-two
  // DEPTH the address space is larger than the array, so this is reachable.
  //
  // The comparison is generated rather than written unconditionally because
  // ADDR_WIDTH'(DEPTH) wraps to zero when DEPTH is a power of two, which would
  // make the check permanently false and fire on every legal access.
  logic addr_in_range;

  if (2 ** ADDR_WIDTH == DEPTH) begin : g_full_address_space
    assign addr_in_range = 1'b1;
  end else begin : g_partial_address_space
    assign addr_in_range = (addr < ADDR_WIDTH'(DEPTH));
  end

  property p_addr_in_range;
    @(posedge clk) en |-> addr_in_range;
  endproperty
  a_addr_in_range : assert property (p_addr_in_range)
    else $error("ram_sp: address %0d is outside the %0d-word array", addr, DEPTH);
`endif

endmodule

`default_nettype wire
