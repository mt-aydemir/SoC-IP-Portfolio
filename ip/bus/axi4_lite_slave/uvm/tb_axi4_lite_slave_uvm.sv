//=============================================================================
// Testbench   : tb_axi4_lite_slave_uvm
// Description : UVM testbench top for axi4_lite_slave: clock, reset, the DUT
//               and the interface, handed to the environment in
//               axi4_lite_slave_uvm_pkg through the configuration database.
//               The test is chosen with +UVM_TESTNAME. ADDR_WIDTH 12,
//               DATA_WIDTH 32.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`timescale 1ns/1ps

module tb_axi4_lite_slave_uvm;

  import uvm_pkg::*;
  import axi4_lite_slave_uvm_pkg::*;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  axi4_lite_slave_if #(.AW(AW), .DW(DW)) bus (.clk(clk));

  axi4_lite_slave #(.ADDR_WIDTH(AW), .DATA_WIDTH(DW)) dut (
      .clk(clk), .rst_n(bus.rst_n),
      .s_axi_awvalid(bus.awvalid), .s_axi_awready(bus.awready),
      .s_axi_awaddr(bus.awaddr), .s_axi_awprot(bus.awprot),
      .s_axi_wvalid(bus.wvalid), .s_axi_wready(bus.wready),
      .s_axi_wdata(bus.wdata), .s_axi_wstrb(bus.wstrb),
      .s_axi_bvalid(bus.bvalid), .s_axi_bready(bus.bready), .s_axi_bresp(bus.bresp),
      .s_axi_arvalid(bus.arvalid), .s_axi_arready(bus.arready),
      .s_axi_araddr(bus.araddr), .s_axi_arprot(bus.arprot),
      .s_axi_rvalid(bus.rvalid), .s_axi_rready(bus.rready),
      .s_axi_rdata(bus.rdata), .s_axi_rresp(bus.rresp),
      .reg_valid(bus.reg_valid), .reg_ready(bus.reg_ready), .reg_write(bus.reg_write),
      .reg_addr(bus.reg_addr), .reg_wdata(bus.reg_wdata), .reg_strb(bus.reg_strb),
      .reg_prot(bus.reg_prot), .reg_rdata(bus.reg_rdata), .reg_error(bus.reg_error));

  initial begin
    bus.rst_n = 1'b0;
    repeat (5) @(posedge clk);
    #1 bus.rst_n = 1'b1;
  end

  initial begin
    uvm_config_db#(axil_vif_t)::set(null, "*", "vif", bus);
    run_test();
  end

endmodule
