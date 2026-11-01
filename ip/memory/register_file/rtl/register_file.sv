//=============================================================================
// Module      : register_file
// Category    : memory
// Description : Multi-port register file with one write port and a
//               configurable number of asynchronous read ports.
//
// This is the register file a processor datapath needs: reads are
// combinational so an instruction can fetch its operands and use them in the
// same cycle, and the write port is synchronous.
//
// Combinational reads are what make it a register file rather than a RAM. They
// also make it expensive: the storage is inferred as flip-flops with a
// multiplexer per read port, not as a memory macro. Area grows as
// NUM_REGS * DATA_WIDTH flip-flops plus NUM_READ_PORTS multiplexers of
// NUM_REGS inputs each. For anything larger than a few dozen entries, or where
// a cycle of read latency is acceptable, ram_sp or ram_dp is the right block.
//
// Read-during-write
//   A read port addressing the register being written in the same cycle
//   returns the *new* data when BYPASS_WRITE is set, and the old data
//   otherwise. Processor register files normally want the bypass: without it
//   the datapath needs its own forwarding path for the write-back stage.
//
// Register zero
//   With ZERO_REGISTER set, address 0 reads as zero and ignores writes, which
//   is the RISC-V and MIPS convention. The storage for it is optimised away.
//
// Parameters
//   DATA_WIDTH       Width of each register.
//   NUM_REGS         Number of registers. Need not be a power of two.
//   NUM_READ_PORTS   Number of independent asynchronous read ports.
//   ZERO_REGISTER    Hardwire register 0 to zero and ignore writes to it.
//   BYPASS_WRITE     Read-during-write returns the new data.
//
// Latency     : reads combinational, writes visible on the next clock edge
// Reset       : all registers cleared, asynchronous assert, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module register_file #(
    parameter int unsigned DATA_WIDTH     = 32,
    parameter int unsigned NUM_REGS       = 32,
    parameter int unsigned NUM_READ_PORTS = 2,
    // Boolean parameters are int unsigned, not bit, throughout the portfolio:
    // a one-bit parameter overridden from a tool command line receives a
    // 32-bit literal and warns on every build. 0 = off, 1 = on.
    parameter int unsigned ZERO_REGISTER  = 1,
    parameter int unsigned BYPASS_WRITE   = 1
) (
    input  wire                                            clk,
    input  wire                                            rst_n,

    // Write port
    input  wire                                            write_en,
    input  wire  [$clog2(NUM_REGS)-1:0]                    write_addr,
    input  wire  [DATA_WIDTH-1:0]                          write_data,

    // Read ports, packed so the count is a parameter
    input  wire  [NUM_READ_PORTS-1:0][$clog2(NUM_REGS)-1:0] read_addr,
    output logic [NUM_READ_PORTS-1:0][DATA_WIDTH-1:0]       read_data
);

  localparam int unsigned ADDR_WIDTH = $clog2(NUM_REGS);

  // Narrow the integer-typed boolean parameters to one bit once, here, rather
  // than relying on an implicit conversion at each use. Using a 32-bit value
  // directly as a condition warns on every build.
  localparam bit HAS_ZERO_REGISTER = (ZERO_REGISTER != 0);
  localparam bit HAS_BYPASS        = (BYPASS_WRITE  != 0);

  //---------------------------------------------------------------------------
  // Storage.
  //
  // Register 0 is included in the array even when ZERO_REGISTER is set. It is
  // never written and never read, so synthesis removes it entirely; keeping
  // the indexing uniform is worth more than saving the tool the trouble.
  //---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] registers [NUM_REGS];

  //---------------------------------------------------------------------------
  // Address range.
  //
  // When NUM_REGS is a power of two the address space is exactly the array and
  // every address is valid. When it is not - 24 registers needs 5 address bits
  // and leaves 8 unmapped codes - an out-of-range write would index past the
  // array, so it is guarded.
  //
  // The guard is generated rather than written as a plain comparison because
  // ADDR_WIDTH'(NUM_REGS) wraps to zero in the power-of-two case, which would
  // make the comparison constantly false and silently discard every write.
  //---------------------------------------------------------------------------
  logic addr_in_range;

  if (2 ** ADDR_WIDTH == NUM_REGS) begin : g_full_address_space
    assign addr_in_range = 1'b1;
  end else begin : g_partial_address_space
    assign addr_in_range = (write_addr < ADDR_WIDTH'(NUM_REGS));
  end

  // A write to register 0 is discarded rather than suppressed at the caller,
  // so the caller never has to special-case it.
  logic write_accepted;
  assign write_accepted = write_en &&
                          !(HAS_ZERO_REGISTER && (write_addr == '0)) &&
                          addr_in_range;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int unsigned r = 0; r < NUM_REGS; r++) begin
        registers[r] <= '0;
      end
    end else if (write_accepted) begin
      registers[write_addr] <= write_data;
    end
  end

  //---------------------------------------------------------------------------
  // Read ports.
  //
  // Each port is an independent multiplexer over the whole array. The bypass
  // comparison is per port because two ports may address different registers,
  // only one of which is being written.
  //---------------------------------------------------------------------------
  for (genvar p = 0; p < int'(NUM_READ_PORTS); p++) begin : g_read_port
    logic port_reads_zero;
    logic port_bypasses;

    assign port_reads_zero = HAS_ZERO_REGISTER && (read_addr[p] == '0);
    assign port_bypasses   = HAS_BYPASS && write_accepted &&
                             (read_addr[p] == write_addr);

    always_comb begin
      if (port_reads_zero) begin
        read_data[p] = '0;
      end else if (port_bypasses) begin
        read_data[p] = write_data;
      end else begin
        read_data[p] = registers[read_addr[p]];
      end
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DATA_WIDTH < 1) begin
      $fatal(1, "register_file: DATA_WIDTH must be >= 1 (got %0d)", DATA_WIDTH);
    end
    if (NUM_REGS < 2) begin
      $fatal(1, "register_file: NUM_REGS must be >= 2 (got %0d)", NUM_REGS);
    end
    if (NUM_READ_PORTS < 1) begin
      $fatal(1, {"register_file: NUM_READ_PORTS must be >= 1 (got %0d)"},
             NUM_READ_PORTS);
    end
  end

  // Writing outside the array is a caller error. The write is discarded, but
  // silently discarding it would hide the bug.
  property p_write_in_range;
    @(posedge clk) disable iff (!rst_n)
      write_en |-> addr_in_range;
  endproperty
  a_write_in_range : assert property (p_write_in_range)
    else $error("register_file: write to address %0d is outside the %0d-entry array",
                write_addr, NUM_REGS);
`endif

endmodule

`default_nettype wire
