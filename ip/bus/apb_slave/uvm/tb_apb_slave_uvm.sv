//=============================================================================
// Testbench   : tb_apb_slave_uvm
// Description : UVM testbench top for apb_slave: clock, reset, the DUT and
//               the interface, handed to the environment in
//               apb_slave_uvm_pkg through the configuration database. The
//               test is chosen with +UVM_TESTNAME.
//
// REGISTERED selects the response mode under test, at ADDR_WIDTH 12 and
// DATA_WIDTH 32.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`timescale 1ns/1ps

module tb_apb_slave_uvm #(
    parameter int unsigned REGISTERED = 1
);

  import uvm_pkg::*;
  import apb_slave_uvm_pkg::*;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  apb_slave_if #(.AW(AW), .DW(DW)) bus (.clk(clk));

  apb_slave #(.ADDR_WIDTH(AW), .DATA_WIDTH(DW), .REGISTERED(REGISTERED)) dut (
      .clk(clk), .rst_n(bus.rst_n),
      .psel(bus.psel), .penable(bus.penable), .pwrite(bus.pwrite), .paddr(bus.paddr),
      .pwdata(bus.pwdata), .pstrb(bus.pstrb), .pprot(bus.pprot),
      .pready(bus.pready), .prdata(bus.prdata), .pslverr(bus.pslverr),
      .reg_valid(bus.reg_valid), .reg_ready(bus.reg_ready), .reg_write(bus.reg_write),
      .reg_addr(bus.reg_addr), .reg_wdata(bus.reg_wdata), .reg_strb(bus.reg_strb),
      .reg_prot(bus.reg_prot), .reg_rdata(bus.reg_rdata), .reg_error(bus.reg_error));

  initial begin
    bus.rst_n = 1'b0;
    repeat (5) @(posedge clk);
    #1 bus.rst_n = 1'b1;
  end

  initial begin
    uvm_config_db#(apb_vif_t)::set(null, "*", "vif", bus);
    uvm_config_db#(int unsigned)::set(null, "*", "registered", REGISTERED);
    run_test();
  end

endmodule
