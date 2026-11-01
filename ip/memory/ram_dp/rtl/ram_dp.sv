//=============================================================================
// Module      : ram_dp
// Category    : memory
// Description : True dual-port synchronous RAM. Both ports can read and write,
//               each in its own clock domain.
//
// Written as an inferable array with no vendor primitive, so the same source
// maps onto FPGA block RAM or an ASIC dual-port macro according to the target
// tool's own heuristics.
//
// COLLISION BEHAVIOUR
//   The block does not arbitrate between the ports. Physical dual-port
//   memories do not either, and pretending otherwise in RTL would produce a
//   design that simulates differently from the hardware it becomes. The rules
//   are therefore the memory's own, and the integrator must respect them:
//
//   Read / read, any addresses          always safe
//   Read / write, different addresses   always safe
//   Read / write, same address          the read returns OLD data if the two
//                                       clock edges are far enough apart, and
//                                       is UNDEFINED if they coincide
//   Write / write, same address         UNDEFINED contents afterwards
//
//   "Coincide" means within the memory's own write-through window, which is a
//   physical property of the macro and is not modelled here. Treat any
//   same-address access from both ports in the same cycle as undefined.
//
//   The usual way to satisfy these rules is to partition the address space so
//   the two ports never overlap - one port owns even addresses, or each port
//   owns half the array - or to arbitrate outside the block. For a producer
//   and a consumer that genuinely share data across clock domains, fifo_async
//   is the correct block: it is built on exactly this memory plus the pointer
//   logic that makes the sharing safe.
//
// Parameters
//   DATA_WIDTH    Width of a word. A multiple of 8 if byte enables are used.
//   DEPTH         Number of words. Need not be a power of two.
//   BYTE_ENABLE   Enable per-byte write masking. 0 = off, 1 = on.
//   OUTPUT_REG    Add a registered output stage on both ports. 0/1.
//   INIT_FILE     Optional $readmemh file, loaded in simulation only.
//
// Latency     : 1 cycle, or 2 with OUTPUT_REG
// Reset       : none. See ram_sp for why a memory array is not reset.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module ram_dp #(
    parameter int unsigned DATA_WIDTH  = 32,
    parameter int unsigned DEPTH       = 1024,
    parameter int unsigned BYTE_ENABLE = 1,
    parameter int unsigned OUTPUT_REG  = 0,
    // Untyped rather than `parameter string`: Yosys does not accept
    // the string data type in a parameter declaration, and the block
    // must synthesise. A string literal default still reaches
    // $readmemh correctly in simulation.
    parameter       INIT_FILE   = ""
) (
    // Port A
    input  wire                       clk_a,
    input  wire                       en_a,
    input  wire                       we_a,
    input  wire  [(DATA_WIDTH/8)-1:0] be_a,
    input  wire  [$clog2(DEPTH)-1:0]  addr_a,
    input  wire  [DATA_WIDTH-1:0]     wdata_a,
    output logic [DATA_WIDTH-1:0]     rdata_a,

    // Port B
    input  wire                       clk_b,
    input  wire                       en_b,
    input  wire                       we_b,
    input  wire  [(DATA_WIDTH/8)-1:0] be_b,
    input  wire  [$clog2(DEPTH)-1:0]  addr_b,
    input  wire  [DATA_WIDTH-1:0]     wdata_b,
    output logic [DATA_WIDTH-1:0]     rdata_b
);

  localparam int unsigned ADDR_WIDTH = $clog2(DEPTH);
  localparam int unsigned NUM_BYTES  = DATA_WIDTH / 8;

  localparam bit USE_BYTE_ENABLE = (BYTE_ENABLE != 0);
  localparam bit USE_OUTPUT_REG  = (OUTPUT_REG  != 0);

  //---------------------------------------------------------------------------
  // Shared storage.
  //
  // Written from two clocked processes, one per port. That is precisely the
  // structure synthesisers recognise as a true dual-port memory, and it is
  // also what makes the collision rules above the caller's responsibility:
  // there is no arbitration here because there is none in the hardware.
  //---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] mem [DEPTH];

  logic [DATA_WIDTH-1:0] read_a;
  logic [DATA_WIDTH-1:0] read_b;

  //---------------------------------------------------------------------------
  // Port A
  //---------------------------------------------------------------------------
  always_ff @(posedge clk_a) begin
    if (en_a) begin
      if (we_a) begin
        if (USE_BYTE_ENABLE) begin
          for (int unsigned b = 0; b < NUM_BYTES; b++) begin
            if (be_a[b]) begin
              mem[addr_a][b*8 +: 8] <= wdata_a[b*8 +: 8];
            end
          end
        end else begin
          mem[addr_a] <= wdata_a;
        end
      end
      read_a <= mem[addr_a];
    end
  end

  //---------------------------------------------------------------------------
  // Port B
  //---------------------------------------------------------------------------
  always_ff @(posedge clk_b) begin
    if (en_b) begin
      if (we_b) begin
        if (USE_BYTE_ENABLE) begin
          for (int unsigned b = 0; b < NUM_BYTES; b++) begin
            if (be_b[b]) begin
              mem[addr_b][b*8 +: 8] <= wdata_b[b*8 +: 8];
            end
          end
        end else begin
          mem[addr_b] <= wdata_b;
        end
      end
      read_b <= mem[addr_b];
    end
  end

  //---------------------------------------------------------------------------
  // Optional output registers
  //---------------------------------------------------------------------------
  if (USE_OUTPUT_REG) begin : g_output_reg

    always_ff @(posedge clk_a) begin
      if (en_a) begin
        rdata_a <= read_a;
      end
    end

    always_ff @(posedge clk_b) begin
      if (en_b) begin
        rdata_b <= read_b;
      end
    end

  end else begin : g_no_output_reg

    assign rdata_a = read_a;
    assign rdata_b = read_b;

  end

  //---------------------------------------------------------------------------
  // Simulation-only initialisation and checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DATA_WIDTH < 8) begin
      $fatal(1, "ram_dp: DATA_WIDTH must be >= 8 (got %0d)", DATA_WIDTH);
    end
    if (USE_BYTE_ENABLE && (DATA_WIDTH % 8 != 0)) begin
      $fatal(1, {"ram_dp: DATA_WIDTH must be a multiple of 8 when byte ",
                 "enables are used (got %0d)"}, DATA_WIDTH);
    end
    if (DEPTH < 2) begin
      $fatal(1, "ram_dp: DEPTH must be >= 2 (got %0d)", DEPTH);
    end
  end

  initial begin : memory_init
    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, mem);
    end
  end

  // Generated rather than written unconditionally: ADDR_WIDTH'(DEPTH) wraps to
  // zero when DEPTH is a power of two, which would make the check permanently
  // false and fire on every legal access.
  logic addr_a_in_range;
  logic addr_b_in_range;

  if (2 ** ADDR_WIDTH == DEPTH) begin : g_full_address_space
    assign addr_a_in_range = 1'b1;
    assign addr_b_in_range = 1'b1;
  end else begin : g_partial_address_space
    assign addr_a_in_range = (addr_a < ADDR_WIDTH'(DEPTH));
    assign addr_b_in_range = (addr_b < ADDR_WIDTH'(DEPTH));
  end

  property p_addr_a_in_range;
    @(posedge clk_a) en_a |-> addr_a_in_range;
  endproperty
  a_addr_a_in_range : assert property (p_addr_a_in_range)
    else $error("ram_dp: port A address %0d is outside the %0d-word array",
                addr_a, DEPTH);

  property p_addr_b_in_range;
    @(posedge clk_b) en_b |-> addr_b_in_range;
  endproperty
  a_addr_b_in_range : assert property (p_addr_b_in_range)
    else $error("ram_dp: port B address %0d is outside the %0d-word array",
                addr_b, DEPTH);
`endif

endmodule

`default_nettype wire
