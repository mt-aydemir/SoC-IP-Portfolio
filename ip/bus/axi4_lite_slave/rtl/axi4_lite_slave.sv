//=============================================================================
// Module      : axi4_lite_slave
// Category    : bus
// Description : AMBA AXI4-Lite subordinate, bridging reads and writes onto a
//               simple register request port.
//
// Each of the five AXI channels is handled independently, as the protocol
// requires: a write address and its data may arrive in either order or in the
// same cycle, and the read channels do not wait for the write channels. Every
// write becomes one request on the register port and one B response; every
// read becomes one request and one R response.
//
// Register port
//   reg_valid / reg_ready  A request transfers on the edge where both are
//                          high. reg_valid and the payload are held until it
//                          does; reg_valid never depends on reg_ready.
//   reg_write, reg_addr,   The access. reg_addr is the byte address from
//   reg_wdata, reg_strb,   AWADDR or ARADDR; reg_wdata and reg_strb are WDATA
//   reg_prot               and WSTRB on a write and zero on a read; reg_prot
//                          is AWPROT or ARPROT.
//   reg_rdata, reg_error   The response, sampled on the accepting edge: read
//                          data, and an error that becomes SLVERR.
//
// It is the same port as apb_slave's, so register logic written once sits
// behind either bus.
//
// Structure
//   AW, W and AR each have a one-entry holding register; the channel's ready
//   is high whenever its register is empty. A write is ready to issue once
//   both AW and W are held and no B response is outstanding; a read once AR
//   is held and no R response is outstanding. When both are ready the write
//   goes first, and the choice is locked while the request waits for
//   reg_ready, which is what keeps the request stable. B and R are
//   registered.
//
//   Neither direction can starve the other, and no arbiter state is needed
//   for that: a direction just served cannot be ready again in the next
//   cycle - its response register is full and its holding registers empty -
//   so the other direction always gets the next request slot.
//
//   Every output is a flip-flop or a function of flip-flops only: there is no
//   combinational path from any AXI input to any AXI output.
//
// Throughput  : one write and one read can be in flight at once; each
//               direction completes at most one transfer every two cycles,
//               plus the register block's wait states.
// Responses   : OKAY (2'b00), or SLVERR (2'b10) when reg_error is high.
//
// Parameters
//   ADDR_WIDTH  AWADDR/ARADDR width. 2 to 64.
//   DATA_WIDTH  WDATA/RDATA width: 32 or 64, as AXI4-Lite allows.
//
// Reset       : asynchronous assertion, synchronous release, active low.
//               BVALID and RVALID low, nothing held.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module axi4_lite_slave #(
    parameter int unsigned ADDR_WIDTH = 12,
    parameter int unsigned DATA_WIDTH = 32
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // Write address channel
    input  wire                     s_axi_awvalid,
    output logic                    s_axi_awready,
    input  wire  [ADDR_WIDTH-1:0]   s_axi_awaddr,
    input  wire  [2:0]              s_axi_awprot,

    // Write data channel
    input  wire                     s_axi_wvalid,
    output logic                    s_axi_wready,
    input  wire  [DATA_WIDTH-1:0]   s_axi_wdata,
    input  wire  [DATA_WIDTH/8-1:0] s_axi_wstrb,

    // Write response channel
    output logic                    s_axi_bvalid,
    input  wire                     s_axi_bready,
    output logic [1:0]              s_axi_bresp,

    // Read address channel
    input  wire                     s_axi_arvalid,
    output logic                    s_axi_arready,
    input  wire  [ADDR_WIDTH-1:0]   s_axi_araddr,
    input  wire  [2:0]              s_axi_arprot,

    // Read data channel
    output logic                    s_axi_rvalid,
    input  wire                     s_axi_rready,
    output logic [DATA_WIDTH-1:0]   s_axi_rdata,
    output logic [1:0]              s_axi_rresp,

    // Register request port
    output logic                    reg_valid,
    input  wire                     reg_ready,
    output logic                    reg_write,
    output logic [ADDR_WIDTH-1:0]   reg_addr,
    output logic [DATA_WIDTH-1:0]   reg_wdata,
    output logic [DATA_WIDTH/8-1:0] reg_strb,
    output logic [2:0]              reg_prot,
    input  wire  [DATA_WIDTH-1:0]   reg_rdata,
    input  wire                     reg_error
);

  localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8;

  localparam logic [1:0] RESP_OKAY   = 2'b00;
  localparam logic [1:0] RESP_SLVERR = 2'b10;

  //---------------------------------------------------------------------------
  // Channel holding registers
  //---------------------------------------------------------------------------
  logic                  aw_full, w_full, ar_full;
  logic [ADDR_WIDTH-1:0] aw_addr, ar_addr;
  logic [2:0]            aw_prot, ar_prot;
  logic [DATA_WIDTH-1:0] w_data;
  logic [STRB_WIDTH-1:0] w_strb;

  assign s_axi_awready = !aw_full;
  assign s_axi_wready  = !w_full;
  assign s_axi_arready = !ar_full;

  //---------------------------------------------------------------------------
  // Request selection
  //---------------------------------------------------------------------------
  logic write_pending, read_pending;
  logic locked, locked_write;
  logic sel_write, taken;

  assign write_pending = aw_full && w_full && !s_axi_bvalid;
  assign read_pending  = ar_full && !s_axi_rvalid;

  assign sel_write = locked ? locked_write : write_pending;

  assign reg_valid = locked || write_pending || read_pending;
  assign reg_write = sel_write;
  assign reg_addr  = sel_write ? aw_addr : ar_addr;
  assign reg_prot  = sel_write ? aw_prot : ar_prot;
  assign reg_wdata = sel_write ? w_data  : '0;
  assign reg_strb  = sel_write ? w_strb  : '0;

  assign taken = reg_valid && reg_ready;

  //---------------------------------------------------------------------------
  // State
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      aw_full      <= 1'b0;
      w_full       <= 1'b0;
      ar_full      <= 1'b0;
      aw_addr      <= '0;
      aw_prot      <= '0;
      w_data       <= '0;
      w_strb       <= '0;
      ar_addr      <= '0;
      ar_prot      <= '0;
      locked       <= 1'b0;
      locked_write <= 1'b0;
      s_axi_bvalid <= 1'b0;
      s_axi_bresp  <= RESP_OKAY;
      s_axi_rvalid <= 1'b0;
      s_axi_rdata  <= '0;
      s_axi_rresp  <= RESP_OKAY;
    end else begin
      // Channel captures. A holding register empties only when its request
      // is taken, and its ready was low in that cycle, so a capture and a
      // release never coincide.
      if (s_axi_awvalid && s_axi_awready) begin
        aw_full <= 1'b1;
        aw_addr <= s_axi_awaddr;
        aw_prot <= s_axi_awprot;
      end
      if (s_axi_wvalid && s_axi_wready) begin
        w_full <= 1'b1;
        w_data <= s_axi_wdata;
        w_strb <= s_axi_wstrb;
      end
      if (s_axi_arvalid && s_axi_arready) begin
        ar_full <= 1'b1;
        ar_addr <= s_axi_araddr;
        ar_prot <= s_axi_arprot;
      end

      // Lock the choice while a request waits.
      if (reg_valid && !reg_ready) begin
        locked       <= 1'b1;
        locked_write <= sel_write;
      end else begin
        locked       <= 1'b0;
      end

      // A taken request releases its holding registers and posts a response.
      if (taken) begin
        if (sel_write) begin
          aw_full      <= 1'b0;
          w_full       <= 1'b0;
          s_axi_bvalid <= 1'b1;
          s_axi_bresp  <= reg_error ? RESP_SLVERR : RESP_OKAY;
        end else begin
          ar_full      <= 1'b0;
          s_axi_rvalid <= 1'b1;
          s_axi_rdata  <= reg_rdata;
          s_axi_rresp  <= reg_error ? RESP_SLVERR : RESP_OKAY;
        end
      end

      // Responses retire on their own handshakes. A response cannot be both
      // posted and retired in one cycle: it is only posted when not valid.
      if (s_axi_bvalid && s_axi_bready) begin
        s_axi_bvalid <= 1'b0;
      end
      if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Protocol checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (ADDR_WIDTH < 2 || ADDR_WIDTH > 64) begin
      $fatal(1, "axi4_lite_slave: ADDR_WIDTH must be 2 to 64 (got %0d)", ADDR_WIDTH);
    end
    if (DATA_WIDTH != 32 && DATA_WIDTH != 64) begin
      $fatal(1, "axi4_lite_slave: DATA_WIDTH must be 32 or 64 (got %0d)", DATA_WIDTH);
    end
  end

  // The manager's side: once valid, a channel holds valid and its payload
  // until the handshake.
  property p_aw_held;
    @(posedge clk) disable iff (!rst_n)
      (s_axi_awvalid && !s_axi_awready) |=>
        (s_axi_awvalid && $stable(s_axi_awaddr) && $stable(s_axi_awprot));
  endproperty
  a_aw_held : assert property (p_aw_held)
    else $error("axi4_lite_slave: AW changed before AWREADY");

  property p_w_held;
    @(posedge clk) disable iff (!rst_n)
      (s_axi_wvalid && !s_axi_wready) |=>
        (s_axi_wvalid && $stable(s_axi_wdata) && $stable(s_axi_wstrb));
  endproperty
  a_w_held : assert property (p_w_held)
    else $error("axi4_lite_slave: W changed before WREADY");

  property p_ar_held;
    @(posedge clk) disable iff (!rst_n)
      (s_axi_arvalid && !s_axi_arready) |=>
        (s_axi_arvalid && $stable(s_axi_araddr) && $stable(s_axi_arprot));
  endproperty
  a_ar_held : assert property (p_ar_held)
    else $error("axi4_lite_slave: AR changed before ARREADY");

  // The block's side: responses and the register request hold until taken.
  property p_b_held;
    @(posedge clk) disable iff (!rst_n)
      (s_axi_bvalid && !s_axi_bready) |=> (s_axi_bvalid && $stable(s_axi_bresp));
  endproperty
  a_b_held : assert property (p_b_held)
    else $error("axi4_lite_slave: B changed before BREADY");

  property p_r_held;
    @(posedge clk) disable iff (!rst_n)
      (s_axi_rvalid && !s_axi_rready) |=>
        (s_axi_rvalid && $stable(s_axi_rdata) && $stable(s_axi_rresp));
  endproperty
  a_r_held : assert property (p_r_held)
    else $error("axi4_lite_slave: R changed before RREADY");

  property p_request_held;
    @(posedge clk) disable iff (!rst_n)
      (reg_valid && !reg_ready) |=>
        (reg_valid && $stable(reg_write) && $stable(reg_addr)
         && $stable(reg_wdata) && $stable(reg_strb) && $stable(reg_prot));
  endproperty
  a_request_held : assert property (p_request_held)
    else $error("axi4_lite_slave: register request changed before reg_ready");
`endif

endmodule

`default_nettype wire
