//=============================================================================
// Module      : apb_slave_formal
// Category    : bus
// Description : Formal property wrapper for apb_slave, both response modes.
//
// Each mode has its own instance and its own APB requester, constrained by
// assumptions to the AMBA APB4 rules: a setup phase is followed by an access
// phase with the same signals; the transfer's signals hold until PREADY; a
// completed transfer is followed by idle or a new setup phase; reads carry
// no strobes. The register side - reg_ready, reg_rdata, reg_error - is
// unconstrained. For every such sequence from reset:
//
//   ONE REQUEST   each transfer issues exactly one register request: none
//                 outside an access phase, never a second one, and the
//                 transfer cannot complete without one
//   PAYLOAD       the request carries the transfer's write, address, data,
//                 strobes and protection, and holds them until taken
//   RESPONSE      REGISTERED=0: PREADY, PRDATA and PSLVERR are reg_ready,
//                 reg_rdata and reg_error. REGISTERED=1: PREADY rises
//                 exactly one cycle after the request is accepted, with the
//                 read data (zero on a write) and the error captured on that
//                 edge; PSLVERR is never high without PREADY
//
// Covers in both modes: a write that waits two cycles for reg_ready, a read
// that ends in PSLVERR, and a transfer completing within three cycles of
// the previous one - back to back.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module apb_slave_formal (
    input wire       clk,
    input wire       rst_n,
    input wire [1:0] psel,
    input wire [1:0] penable,
    input wire [1:0] pwrite,
    input wire [7:0] paddr,     // 4 bits per instance
    input wire [15:0] pwdata,   // 8 bits per instance
    input wire [1:0] pstrb,
    input wire [5:0] pprot,     // 3 bits per instance
    input wire [1:0] reg_ready,
    input wire [15:0] reg_rdata,
    input wire [1:0] reg_error
);

  initial assume (!rst_n);

  for (genvar r = 0; r < 2; r++) begin : g_mode
    apb_slave_check #(.REGISTERED(r)) u_check (
        .clk(clk), .rst_n(rst_n),
        .psel(psel[r]), .penable(penable[r]), .pwrite(pwrite[r]),
        .paddr(paddr[4*r +: 4]), .pwdata(pwdata[8*r +: 8]), .pstrb(pstrb[r]),
        .pprot(pprot[3*r +: 3]), .reg_ready(reg_ready[r]),
        .reg_rdata(reg_rdata[8*r +: 8]), .reg_error(reg_error[r]));
  end

endmodule

module apb_slave_check #(
    parameter int unsigned REGISTERED = 0
) (
    input wire       clk,
    input wire       rst_n,
    input wire       psel,
    input wire       penable,
    input wire       pwrite,
    input wire [3:0] paddr,
    input wire [7:0] pwdata,
    input wire       pstrb,
    input wire [2:0] pprot,
    input wire       reg_ready,
    input wire [7:0] reg_rdata,
    input wire       reg_error
);

  logic       pready, pslverr, reg_valid, reg_write, reg_strb;
  logic [7:0] prdata, reg_wdata;
  logic [3:0] reg_addr;
  logic [2:0] reg_prot;

  apb_slave #(.ADDR_WIDTH(4), .DATA_WIDTH(8), .REGISTERED(REGISTERED)) dut (
      .clk(clk), .rst_n(rst_n),
      .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
      .pwdata(pwdata), .pstrb(pstrb), .pprot(pprot),
      .pready(pready), .prdata(prdata), .pslverr(pslverr),
      .reg_valid(reg_valid), .reg_ready(reg_ready), .reg_write(reg_write),
      .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_strb(reg_strb),
      .reg_prot(reg_prot), .reg_rdata(reg_rdata), .reg_error(reg_error));

  logic access, done, take;
  assign access = psel && penable;
  assign done   = access && pready;
  assign take   = reg_valid && reg_ready;

  // The previous cycle, for the requester's rules and for the response.
  logic       p_setup, p_waiting, p_done, p_take, p_write, p_strb, issued;
  logic [3:0] p_addr;
  logic [7:0] p_wdata, p_rdata;
  logic [2:0] p_prot;
  logic       p_error;
  logic       stall_req;
  logic [1:0] waits;
  logic [2:0] recent_done;      // a transfer completed in each of the last 3 cycles

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      {p_setup, p_waiting, p_done, p_take, p_write, p_strb, p_error} <= '0;
      {p_addr, p_wdata, p_rdata, p_prot} <= '0;
      issued    <= 1'b0;
      stall_req <= 1'b0;
      waits     <= '0;
    end else begin
      p_setup   <= psel && !penable;
      p_waiting <= access && !pready;
      p_done    <= done;
      p_take    <= take;
      p_write   <= pwrite;
      p_addr    <= paddr;
      p_wdata   <= pwdata;
      p_strb    <= pstrb;
      p_prot    <= pprot;
      p_rdata   <= reg_rdata;
      p_error   <= reg_error;
      stall_req <= reg_valid && !reg_ready;
      if (done)      issued <= 1'b0;
      else if (take) issued <= 1'b1;
      if (!access)                waits <= '0;
      else if (!reg_ready && waits != 2'd3) waits <= waits + 2'd1;
    end
  end

  // The requester obeys APB4.
  always @(*) begin
    if (rst_n) begin
      if (penable) assume (psel);
      if (psel && penable) assume (p_setup || p_waiting);
      if (p_setup || p_waiting)
        assume (access && pwrite == p_write && paddr == p_addr && pprot == p_prot
                && pstrb == p_strb && (!pwrite || pwdata == p_wdata));
      if (psel && !pwrite) assume (pstrb == 1'b0);
    end
  end

  always @(*) begin
    if (rst_n) begin
      // One request per transfer
      if (reg_valid) assert (access);
      if (take) assert (!issued);
      if (done) assert (issued || take);
      // Payload
      assert (reg_write == pwrite && reg_addr == paddr && reg_wdata == pwdata
              && reg_strb == pstrb && reg_prot == pprot);
      if (stall_req) assert (reg_valid);
      // Response
      if (REGISTERED == 0) begin
        assert (!issued);           // request and completion share a cycle
        if (access) assert (pready == reg_ready && reg_valid);
        assert (prdata == reg_rdata && pslverr == reg_error);
      end else begin
        assert (pready == p_take);
        assert (issued == pready);
        if (pready) assert (prdata == (p_write ? 8'h00 : p_rdata) && pslverr == p_error);
        if (!pready) assert (!pslverr);
      end
    end
  end

  always @(*) begin
    if (rst_n) begin
      cover (done && pwrite && waits == 2'd2);
      cover (done && !pwrite && pslverr);
      cover (done && recent_done != 3'b000);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) recent_done <= '0;
    else        recent_done <= {recent_done[1:0], done};
  end

endmodule

`default_nettype wire
