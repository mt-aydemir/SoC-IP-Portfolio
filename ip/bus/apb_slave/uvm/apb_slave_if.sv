//=============================================================================
// Interface   : apb_slave_if
// Category    : bus
// Description : The two ports of apb_slave - the APB4 completer side and the
//               register request side - as one interface, for the UVM
//               environment in apb_slave_uvm_pkg.
//
// There is no clocking block. Drivers assign one time unit after the rising
// edge and monitors sample on the falling edge, which keeps every sample away
// from the edge without the virtual-interface-through-clocking path, which
// the simulator does not yet propagate reliably (verilator/verilator#7688).
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

interface apb_slave_if #(
    parameter int unsigned AW = 12,
    parameter int unsigned DW = 32
) (
    input wire clk
);

  logic          rst_n;

  // APB4 completer
  logic          psel;
  logic          penable;
  logic          pwrite;
  logic [AW-1:0] paddr;
  logic [DW-1:0] pwdata;
  logic [DW/8-1:0] pstrb;
  logic [2:0]    pprot;
  logic          pready;
  logic [DW-1:0] prdata;
  logic          pslverr;

  // Register request port
  logic          reg_valid;
  logic          reg_ready;
  logic          reg_write;
  logic [AW-1:0] reg_addr;
  logic [DW-1:0] reg_wdata;
  logic [DW/8-1:0] reg_strb;
  logic [2:0]    reg_prot;
  logic [DW-1:0] reg_rdata;
  logic          reg_error;

endinterface

`default_nettype wire
