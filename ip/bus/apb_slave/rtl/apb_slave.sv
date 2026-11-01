//=============================================================================
// Module      : apb_slave
// Category    : bus
// Description : AMBA APB4 completer, bridging APB transfers onto a simple
//               register request port.
//
// The block turns each APB transfer into exactly one request on the register
// port and returns that request's response as the transfer's PRDATA and
// PSLVERR. The register logic behind it sees no APB at all: it accepts a
// request with reg_ready and answers in the same cycle.
//
// Register port
//   reg_valid / reg_ready  A request transfers on the edge where both are
//                          high, exactly once per APB transfer. reg_valid
//                          and the payload are held until it does.
//   reg_write, reg_addr,   The access. reg_addr is the byte address from
//   reg_wdata, reg_strb,   PADDR; reg_strb is PSTRB, which APB4 requires
//   reg_prot               to be zero on a read; reg_prot is PPROT.
//   reg_rdata, reg_error   The response, sampled on the accepting edge:
//                          read data, and an error that becomes PSLVERR.
//
// A block with a combinational register read - gpio, for one - connects with
// reg_ready tied high and its write enable as reg_valid && reg_write. A block
// that needs time asserts reg_ready late and the APB transfer waits.
//
// REGISTERED selects how the response reaches the bus:
//   0  PREADY, PRDATA and PSLVERR are reg_ready, reg_rdata and reg_error,
//      combinationally. A ready register block completes in the minimum two
//      APB cycles, at the cost of a combinational path from PADDR through
//      the register read back to PRDATA.
//   1  The response is captured into registers and PREADY rises the cycle
//      after the request is accepted: one wait state, and every APB output
//      a flip-flop. The register port then never sees the next transfer's
//      setup phase.
//
// Parameters
//   ADDR_WIDTH  PADDR width. 2 to 32.
//   DATA_WIDTH  PRDATA/PWDATA width: 8, 16 or 32 (APB's maximum).
//   REGISTERED  0 or 1, as above.
//
// Latency     : REGISTERED=0: none beyond reg_ready. REGISTERED=1: one cycle.
// Reset       : asynchronous assertion, synchronous release, active low.
//               PREADY low, no request outstanding.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module apb_slave #(
    parameter int unsigned ADDR_WIDTH = 12,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned REGISTERED = 1
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // APB4 completer
    input  wire                     psel,
    input  wire                     penable,
    input  wire                     pwrite,
    input  wire  [ADDR_WIDTH-1:0]   paddr,
    input  wire  [DATA_WIDTH-1:0]   pwdata,
    input  wire  [DATA_WIDTH/8-1:0] pstrb,
    input  wire  [2:0]              pprot,
    output logic                    pready,
    output logic [DATA_WIDTH-1:0]   prdata,
    output logic                    pslverr,

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

  // APB holds every address and control signal stable from the setup phase
  // to the end of the transfer, so the payload is simply forwarded.
  assign reg_write = pwrite;
  assign reg_addr  = paddr;
  assign reg_wdata = pwdata;
  assign reg_strb  = pstrb;
  assign reg_prot  = pprot;

  logic access;

  assign access = psel && penable;

  generate
    if (REGISTERED == 0) begin : g_direct

      assign reg_valid = access;
      assign pready    = reg_ready;
      assign prdata    = reg_rdata;
      assign pslverr   = reg_error;

    end else begin : g_registered

      // done marks a transfer whose request has been accepted and whose
      // response is waiting in the registers for the completing edge. It
      // keeps the request from being issued a second time in that cycle.
      logic                  done_q;
      logic [DATA_WIDTH-1:0] rdata_q;
      logic                  error_q;

      assign reg_valid = access && !done_q;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          done_q  <= 1'b0;
          rdata_q <= '0;
          error_q <= 1'b0;
        end else if (done_q) begin
          // pready is high now, so this edge completes the transfer.
          done_q  <= 1'b0;
        end else if (reg_valid && reg_ready) begin
          done_q  <= 1'b1;
          rdata_q <= reg_write ? '0 : reg_rdata;
          error_q <= reg_error;
        end
      end

      assign pready  = done_q;
      assign prdata  = rdata_q;
      assign pslverr = done_q && error_q;

    end
  endgenerate

  //---------------------------------------------------------------------------
  // Protocol checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (ADDR_WIDTH < 2 || ADDR_WIDTH > 32) begin
      $fatal(1, "apb_slave: ADDR_WIDTH must be 2 to 32 (got %0d)", ADDR_WIDTH);
    end
    if (DATA_WIDTH != 8 && DATA_WIDTH != 16 && DATA_WIDTH != 32) begin
      $fatal(1, "apb_slave: DATA_WIDTH must be 8, 16 or 32 (got %0d)", DATA_WIDTH);
    end
    if (REGISTERED > 1) begin
      $fatal(1, "apb_slave: REGISTERED must be 0 or 1 (got %0d)", REGISTERED);
    end
  end

  // The requester's side of APB: an access phase follows a setup phase, and
  // the transfer's signals hold until PREADY completes it.
  property p_access_follows_setup;
    @(posedge clk) disable iff (!rst_n)
      (psel && !penable) |=> (psel && penable);
  endproperty
  a_access_follows_setup : assert property (p_access_follows_setup)
    else $error("apb_slave: PENABLE did not follow the setup phase");

  property p_transfer_held;
    @(posedge clk) disable iff (!rst_n)
      (access && !pready) |=>
        (access && $stable(pwrite) && $stable(paddr) && $stable(pprot)
         && $stable(pstrb) && (!pwrite || $stable(pwdata)));
  endproperty
  a_transfer_held : assert property (p_transfer_held)
    else $error("apb_slave: transfer changed before PREADY");

  property p_no_read_strobes;
    @(posedge clk) disable iff (!rst_n)
      (psel && !pwrite) |-> (pstrb == '0);
  endproperty
  a_no_read_strobes : assert property (p_no_read_strobes)
    else $error("apb_slave: PSTRB active during a read");

  // The block's side of the register port: a request is held until taken.
  property p_request_held;
    @(posedge clk) disable iff (!rst_n)
      (reg_valid && !reg_ready) |=>
        (reg_valid && $stable(reg_write) && $stable(reg_addr)
         && $stable(reg_wdata) && $stable(reg_strb) && $stable(reg_prot));
  endproperty
  a_request_held : assert property (p_request_held)
    else $error("apb_slave: register request changed before reg_ready");
`endif

endmodule

`default_nettype wire
