//=============================================================================
// Module      : axi4_lite_slave_formal
// Category    : bus
// Description : Formal property wrapper for axi4_lite_slave.
//
// The manager is assumed to obey AXI4-Lite - AWVALID, WVALID and ARVALID
// stay high until their handshake - and drives payloads computed from each
// channel's own handshake count: AWADDR and AWPROT from the AW count, WDATA
// and WSTRB from the W count, ARADDR and ARPROT from the AR count. BREADY,
// RREADY and the whole register side are unconstrained. For every such
// sequence from reset:
//
//   PAIRING   the n-th write request carries the n-th AW and the n-th W -
//             address, protection, data and strobes - and the n-th read
//             request the n-th AR, with zero data and strobes
//   ONE EACH  every AW+W pair becomes exactly one write request and one B
//             response, every AR one read request and one R response; a
//             channel is ready exactly when its holding register is free,
//             and BVALID and RVALID are high exactly while a response is
//             owed
//   RESPONSE  B and R carry SLVERR exactly when reg_error was high on the
//             request's accepting edge, and R carries that edge's reg_rdata
//   HOLD      a register request, a B and an R that are not taken stay
//   FAIRNESS  a request is never followed by another in the same direction
//             on the next accepting edge, so neither direction can starve
//
// The holding registers and the request lock are probed for induction.
//
// Covers: a write whose W arrives before its AW, a read and a write in
// flight together, a SLVERR on each response channel, and alternation
// under saturation (a write request followed directly by a read request).
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module axi4_lite_slave_formal (
    input wire        clk,
    input wire        rst_n,
    input wire        awvalid,
    input wire        wvalid,
    input wire        arvalid,
    input wire        bready,
    input wire        rready,
    input wire        reg_ready,
    input wire [31:0] reg_rdata,
    input wire        reg_error
);

  // Channel payloads from the channel's handshake count.
  function automatic logic [3:0]  aw_addr_of(input logic [3:0] n); aw_addr_of = n;            endfunction
  function automatic logic [2:0]  aw_prot_of(input logic [3:0] n); aw_prot_of = n[2:0] ^ 3'd5; endfunction
  function automatic logic [31:0] w_data_of (input logic [3:0] n); w_data_of  = {8{n}};        endfunction
  function automatic logic [3:0]  w_strb_of (input logic [3:0] n); w_strb_of  = ~n;            endfunction
  function automatic logic [3:0]  ar_addr_of(input logic [3:0] n); ar_addr_of = n ^ 4'hA;      endfunction
  function automatic logic [2:0]  ar_prot_of(input logic [3:0] n); ar_prot_of = n[3:1];        endfunction

  logic [3:0] aw_n, w_n, ar_n, wreq_n, rreq_n, b_n, r_n;

  logic        awready, wready, arready, bvalid, rvalid;
  logic [1:0]  bresp, rresp;
  logic [31:0] rdata;
  logic        reg_valid, reg_write;
  logic [3:0]  reg_addr, reg_strb;
  logic [31:0] reg_wdata;
  logic [2:0]  reg_prot;

  axi4_lite_slave #(.ADDR_WIDTH(4), .DATA_WIDTH(32)) dut (
      .clk(clk), .rst_n(rst_n),
      .s_axi_awvalid(awvalid), .s_axi_awready(awready),
      .s_axi_awaddr(aw_addr_of(aw_n)), .s_axi_awprot(aw_prot_of(aw_n)),
      .s_axi_wvalid(wvalid), .s_axi_wready(wready),
      .s_axi_wdata(w_data_of(w_n)), .s_axi_wstrb(w_strb_of(w_n)),
      .s_axi_bvalid(bvalid), .s_axi_bready(bready), .s_axi_bresp(bresp),
      .s_axi_arvalid(arvalid), .s_axi_arready(arready),
      .s_axi_araddr(ar_addr_of(ar_n)), .s_axi_arprot(ar_prot_of(ar_n)),
      .s_axi_rvalid(rvalid), .s_axi_rready(rready), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
      .reg_valid(reg_valid), .reg_ready(reg_ready), .reg_write(reg_write),
      .reg_addr(reg_addr), .reg_wdata(reg_wdata), .reg_strb(reg_strb), .reg_prot(reg_prot),
      .reg_rdata(reg_rdata), .reg_error(reg_error));

  // formal-connect: f_aw_full = dut.aw_full
  // formal-connect: f_w_full = dut.w_full
  // formal-connect: f_ar_full = dut.ar_full
  // formal-connect: f_aw_addr = dut.aw_addr
  // formal-connect: f_aw_prot = dut.aw_prot
  // formal-connect: f_w_data = dut.w_data
  // formal-connect: f_w_strb = dut.w_strb
  // formal-connect: f_ar_addr = dut.ar_addr
  // formal-connect: f_ar_prot = dut.ar_prot
  // formal-connect: f_locked = dut.locked
  // formal-connect: f_locked_write = dut.locked_write
  (* keep *) wire        f_aw_full, f_w_full, f_ar_full, f_locked, f_locked_write;
  (* keep *) wire [3:0]  f_aw_addr, f_w_strb, f_ar_addr;
  (* keep *) wire [2:0]  f_aw_prot, f_ar_prot;
  (* keep *) wire [31:0] f_w_data;

  logic aw_hs, w_hs, ar_hs, take, b_hs, r_hs;
  assign aw_hs = awvalid && awready;
  assign w_hs  = wvalid && wready;
  assign ar_hs = arvalid && arready;
  assign take  = reg_valid && reg_ready;
  assign b_hs  = bvalid && bready;
  assign r_hs  = rvalid && rready;

  logic        p_aw_wait, p_w_wait, p_ar_wait, p_req_stall, p_b_stall, p_r_stall;
  logic        p_take_w, p_take_r;
  logic        p_reg_write;
  logic [3:0]  p_reg_addr, p_reg_strb;
  logic [31:0] p_reg_wdata, p_rdata;
  logic [2:0]  p_reg_prot;
  logic [1:0]  p_bresp, p_rresp;
  logic        b_err, r_err;
  logic [31:0] r_data;
  logic        w_before_aw;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      {aw_n, w_n, ar_n, wreq_n, rreq_n, b_n, r_n} <= '0;
      {p_aw_wait, p_w_wait, p_ar_wait, p_req_stall, p_b_stall, p_r_stall} <= '0;
      {p_take_w, p_take_r, p_reg_write} <= '0;
      {p_reg_addr, p_reg_strb, p_reg_wdata, p_rdata, p_reg_prot, p_bresp, p_rresp} <= '0;
      {b_err, r_err, r_data, w_before_aw} <= '0;
    end else begin
      if (aw_hs) aw_n <= aw_n + 4'd1;
      if (w_hs)  w_n  <= w_n + 4'd1;
      if (ar_hs) ar_n <= ar_n + 4'd1;
      if (take && reg_write)  wreq_n <= wreq_n + 4'd1;
      if (take && !reg_write) rreq_n <= rreq_n + 4'd1;
      if (b_hs) b_n <= b_n + 4'd1;
      if (r_hs) r_n <= r_n + 4'd1;
      if (take && reg_write)  b_err <= reg_error;
      if (take && !reg_write) begin
        r_err  <= reg_error;
        r_data <= reg_rdata;
      end
      p_aw_wait   <= awvalid && !awready;
      p_w_wait    <= wvalid && !wready;
      p_ar_wait   <= arvalid && !arready;
      p_req_stall <= reg_valid && !reg_ready;
      p_b_stall   <= bvalid && !bready;
      p_r_stall   <= rvalid && !rready;
      p_take_w    <= take && reg_write;
      p_take_r    <= take && !reg_write;
      p_reg_write <= reg_write;
      p_reg_addr  <= reg_addr;
      p_reg_wdata <= reg_wdata;
      p_reg_strb  <= reg_strb;
      p_reg_prot  <= reg_prot;
      p_bresp     <= bresp;
      p_rresp     <= rresp;
      p_rdata     <= rdata;
      if (w_hs && !f_aw_full && !aw_hs) w_before_aw <= 1'b1;
      else if (take && reg_write)       w_before_aw <= 1'b0;
    end
  end

  initial assume (!rst_n);

  // The manager obeys AXI4-Lite. Payloads depend only on the counts, so
  // they hold by construction.
  always @(*) begin
    if (rst_n) begin
      if (p_aw_wait) assume (awvalid);
      if (p_w_wait)  assume (wvalid);
      if (p_ar_wait) assume (arvalid);
    end
  end

  always @(*) begin
    if (rst_n) begin
      // One each, and the readies
      assert (awready == (aw_n == wreq_n) && awready == !f_aw_full);
      assert (wready == (w_n == wreq_n) && wready == !f_w_full);
      assert (arready == (ar_n == rreq_n) && arready == !f_ar_full);
      assert (aw_n - wreq_n <= 4'd1 && w_n - wreq_n <= 4'd1 && ar_n - rreq_n <= 4'd1);
      assert (bvalid == (wreq_n != b_n) && wreq_n - b_n <= 4'd1);
      assert (rvalid == (rreq_n != r_n) && rreq_n - r_n <= 4'd1);
      // Holding registers hold the next request's payload
      if (f_aw_full) assert (f_aw_addr == aw_addr_of(wreq_n) && f_aw_prot == aw_prot_of(wreq_n));
      if (f_w_full)  assert (f_w_data == w_data_of(wreq_n) && f_w_strb == w_strb_of(wreq_n));
      if (f_ar_full) assert (f_ar_addr == ar_addr_of(rreq_n) && f_ar_prot == ar_prot_of(rreq_n));
      if (f_locked)  assert (f_locked_write ? (f_aw_full && f_w_full) : f_ar_full);
      // Pairing
      if (reg_valid && reg_write)
        assert (reg_addr == aw_addr_of(wreq_n) && reg_prot == aw_prot_of(wreq_n)
                && reg_wdata == w_data_of(wreq_n) && reg_strb == w_strb_of(wreq_n));
      if (reg_valid && !reg_write)
        assert (reg_addr == ar_addr_of(rreq_n) && reg_prot == ar_prot_of(rreq_n)
                && reg_wdata == '0 && reg_strb == '0);
      if (reg_valid) assert (reg_write ? (f_aw_full && f_w_full && !bvalid) : (f_ar_full && !rvalid));
      // Response
      if (bvalid) assert (bresp == (b_err ? 2'b10 : 2'b00));
      if (rvalid) assert (rresp == (r_err ? 2'b10 : 2'b00) && rdata == r_data);
      // Hold
      if (p_req_stall)
        assert (reg_valid && reg_write == p_reg_write && reg_addr == p_reg_addr
                && reg_wdata == p_reg_wdata && reg_strb == p_reg_strb && reg_prot == p_reg_prot);
      if (p_b_stall) assert (bvalid && bresp == p_bresp);
      if (p_r_stall) assert (rvalid && rresp == p_rresp && rdata == p_rdata);
      // Fairness: a request leaves its direction with a response owed and
      // its holding registers empty, so it cannot go again next.
      if (p_take_w) assert (bvalid && !f_aw_full && !f_w_full);
      if (p_take_r) assert (rvalid && !f_ar_full);
      if (p_take_w) assert (!(take && reg_write));
      if (p_take_r) assert (!(take && !reg_write));
    end
  end

  always @(*) begin
    if (rst_n) begin
      cover (take && reg_write && w_before_aw);
      cover (bvalid && rvalid);
      cover (b_hs && bresp == 2'b10);
      cover (r_hs && rresp == 2'b10);
      cover (p_take_w && take && !reg_write);
    end
  end

endmodule

`default_nettype wire
