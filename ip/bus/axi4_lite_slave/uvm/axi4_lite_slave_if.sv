//=============================================================================
// Interface   : axi4_lite_slave_if
// Category    : bus
// Description : The two ports of axi4_lite_slave - the five AXI4-Lite
//               channels and the register request side - as one interface,
//               for the UVM environment in axi4_lite_slave_uvm_pkg.
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

interface axi4_lite_slave_if #(
    parameter int unsigned AW = 12,
    parameter int unsigned DW = 32
) (
    input wire clk
);

  logic            rst_n;

  // Write address, write data, write response
  logic            awvalid, awready;
  logic [AW-1:0]   awaddr;
  logic [2:0]      awprot;
  logic            wvalid, wready;
  logic [DW-1:0]   wdata;
  logic [DW/8-1:0] wstrb;
  logic            bvalid, bready;
  logic [1:0]      bresp;

  // Read address, read data
  logic            arvalid, arready;
  logic [AW-1:0]   araddr;
  logic [2:0]      arprot;
  logic            rvalid, rready;
  logic [DW-1:0]   rdata;
  logic [1:0]      rresp;

  // Register request port
  logic            reg_valid;
  logic            reg_ready;
  logic            reg_write;
  logic [AW-1:0]   reg_addr;
  logic [DW-1:0]   reg_wdata;
  logic [DW/8-1:0] reg_strb;
  logic [2:0]      reg_prot;
  logic [DW-1:0]   reg_rdata;
  logic            reg_error;

endinterface

`default_nettype wire
