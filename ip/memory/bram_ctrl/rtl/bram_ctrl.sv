//=============================================================================
// Module      : bram_ctrl
// Category    : memory
// Description : Block RAM controller. Presents a pipelined request/response
//               interface in front of a single-port synchronous memory.
//
// A synchronous RAM is not directly usable behind a bus. It has fixed read
// latency, it cannot be stalled once a read is issued, and it has no notion of
// back-pressure: the data appears on the cycle it appears, whether or not
// anyone is ready for it. A bus, by contrast, expects flow control in both
// directions and expects a response for every request.
//
// This block bridges the two. It accepts requests only when it can guarantee
// somewhere to put the result, buffers responses so a stalled consumer never
// loses data, and returns exactly one response per accepted request, in order.
//
// FLOW CONTROL
//   The rule that makes it safe is that a request is accepted only if the
//   response buffer will have room for its result on arrival - counting the
//   result already in flight from the previous cycle. Once a read has been
//   issued to the RAM it cannot be recalled, so the room must be reserved
//   before the request is accepted, not after.
//
//   The buffer is two entries deep for the same reason fifo_sync's output
//   stage is: one entry would force the controller to idle whenever the
//   consumer stalled for a single cycle, halving throughput on a bus that
//   back-pressures at all.
//
// WRITE RESPONSES
//   Every accepted request produces a response, writes included. A write
//   response carries no data and exists so the interface is uniform: a bridge
//   in front of this block can map requests and responses one to one without
//   tracking which were writes. Set WRITE_RESPONSE to 0 for a fire-and-forget
//   write port where the bus does not need the completion.
//
// ERRORS
//   An address outside the array is answered with rsp_err rather than being
//   allowed to wrap into a valid location. Silently aliasing a bad address to
//   a good one turns a software bug into corrupted data somewhere unrelated.
//
// Parameters
//   DATA_WIDTH      Word width. A multiple of 8.
//   DEPTH           Words in the array. Need not be a power of two.
//   WRITE_RESPONSE  Produce a response for writes as well as reads. 0/1.
//   INIT_FILE       Optional $readmemh file, simulation only.
//
// Latency     : 2 cycles from accepted read to response, when not stalled
// Throughput  : one request per cycle sustained
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module bram_ctrl #(
    parameter int unsigned DATA_WIDTH     = 32,
    parameter int unsigned DEPTH          = 1024,
    parameter int unsigned WRITE_RESPONSE = 1,
    // Untyped rather than `parameter string`: Yosys does not accept
    // the string data type in a parameter declaration, and the block
    // must synthesise. A string literal default still reaches
    // $readmemh correctly in simulation.
    parameter       INIT_FILE      = ""
) (
    input  wire                       clk,
    input  wire                       rst_n,

    // Request channel
    input  wire                       req_valid,
    output logic                      req_ready,
    input  wire                       req_we,
    input  wire  [$clog2(DEPTH)-1:0]  req_addr,
    input  wire  [(DATA_WIDTH/8)-1:0] req_be,
    input  wire  [DATA_WIDTH-1:0]     req_wdata,

    // Response channel
    output logic                      rsp_valid,
    input  wire                       rsp_ready,
    output logic [DATA_WIDTH-1:0]     rsp_rdata,
    output logic                      rsp_err
);

  localparam int unsigned ADDR_WIDTH   = $clog2(DEPTH);
  localparam int unsigned BUFFER_DEPTH = 2;

  localparam bit RESPOND_TO_WRITES = (WRITE_RESPONSE != 0);

  //---------------------------------------------------------------------------
  // Address checking.
  //
  // Generated rather than written unconditionally: ADDR_WIDTH'(DEPTH) wraps to
  // zero when DEPTH is a power of two, which would make every address look
  // out of range.
  //---------------------------------------------------------------------------
  logic addr_valid;

  if (2 ** ADDR_WIDTH == DEPTH) begin : g_full_address_space
    assign addr_valid = 1'b1;
  end else begin : g_partial_address_space
    assign addr_valid = (req_addr < ADDR_WIDTH'(DEPTH));
  end

  //---------------------------------------------------------------------------
  // Flow control
  //---------------------------------------------------------------------------
  logic       req_fire;
  logic       rsp_fire;
  logic [1:0] buf_count_q;
  logic       inflight_q;       // a response lands in the buffer next cycle
  logic       inflight_err_q;
  logic       expects_response;

  // A write only occupies a response slot when it is answered.
  assign expects_response = !req_we || RESPOND_TO_WRITES;

  // Reserve the slot before accepting: once a read is issued to the RAM its
  // result arrives whether or not anyone has room for it.
  assign req_ready = !expects_response ||
                     ((buf_count_q + 2'(inflight_q)) < 2'(BUFFER_DEPTH));

  assign req_fire = req_valid && req_ready;
  assign rsp_fire = rsp_valid && rsp_ready;

  //---------------------------------------------------------------------------
  // Memory
  //---------------------------------------------------------------------------
  logic                  mem_en;
  logic                  mem_we;
  logic [DATA_WIDTH-1:0] mem_rdata;

  // A request to a bad address must not reach the array at all.
  assign mem_en = req_fire && addr_valid;
  assign mem_we = req_fire && addr_valid && req_we;

  ram_sp #(
      .DATA_WIDTH  (DATA_WIDTH),
      .DEPTH       (DEPTH),
      .BYTE_ENABLE (1),
      .OUTPUT_REG  (0),
      .INIT_FILE   (INIT_FILE)
  ) u_mem (
      .clk   (clk),
      .en    (mem_en),
      .we    (mem_we),
      .be    (req_be),
      .addr  (req_addr),
      .wdata (req_wdata),
      .rdata (mem_rdata)
  );

  //---------------------------------------------------------------------------
  // In-flight tracking
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      inflight_q     <= 1'b0;
      inflight_err_q <= 1'b0;
    end else begin
      inflight_q     <= req_fire && expects_response;
      inflight_err_q <= req_fire && !addr_valid;
    end
  end

  //---------------------------------------------------------------------------
  // Response buffer: two entries, so a one-cycle consumer stall costs nothing.
  //---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] buf_data_q [BUFFER_DEPTH];
  logic [BUFFER_DEPTH-1:0] buf_err_q;

  assign rsp_valid = (buf_count_q != 2'd0);
  assign rsp_rdata = buf_data_q[0];
  assign rsp_err   = buf_err_q[0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      buf_count_q <= 2'd0;
      buf_err_q   <= '0;
      for (int unsigned i = 0; i < BUFFER_DEPTH; i++) begin
        buf_data_q[i] <= '0;
      end
    end else begin
      unique case ({inflight_q, rsp_fire})
        2'b10: begin
          buf_data_q[buf_count_q[0]] <= mem_rdata;
          buf_err_q[buf_count_q[0]]  <= inflight_err_q;
          buf_count_q                <= buf_count_q + 2'd1;
        end
        2'b01: begin
          buf_data_q[0] <= buf_data_q[1];
          buf_err_q[0]  <= buf_err_q[1];
          buf_count_q   <= buf_count_q - 2'd1;
        end
        2'b11: begin
          buf_data_q[0] <= buf_data_q[1];
          buf_err_q[0]  <= buf_err_q[1];
          if (buf_count_q == 2'd1) begin
            buf_data_q[0] <= mem_rdata;
            buf_err_q[0]  <= inflight_err_q;
          end else begin
            buf_data_q[1] <= mem_rdata;
            buf_err_q[1]  <= inflight_err_q;
          end
          buf_count_q <= buf_count_q;
        end
        default: begin
          buf_count_q <= buf_count_q;
        end
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DATA_WIDTH < 8 || (DATA_WIDTH % 8 != 0)) begin
      $fatal(1, {"bram_ctrl: DATA_WIDTH must be a multiple of 8 and >= 8 ",
                 "(got %0d)"}, DATA_WIDTH);
    end
    if (DEPTH < 2) begin
      $fatal(1, "bram_ctrl: DEPTH must be >= 2 (got %0d)", DEPTH);
    end
  end

  // The reservation scheme must never let a result arrive with nowhere to go.
  property p_buffer_never_overruns;
    @(posedge clk) disable iff (!rst_n)
      (inflight_q && !rsp_fire) |-> (buf_count_q < 2'(BUFFER_DEPTH));
  endproperty
  a_buffer_never_overruns : assert property (p_buffer_never_overruns)
    else $error("bram_ctrl: a response arrived with no room in the buffer");

  // The request payload must be stable while stalled.
  property p_request_stable;
    @(posedge clk) disable iff (!rst_n)
      (req_valid && !req_ready) |=> ($stable(req_addr) && $stable(req_we) &&
                                     $stable(req_wdata) && $stable(req_be));
  endproperty
  a_request_stable : assert property (p_request_stable)
    else $error("bram_ctrl: the request changed while it was stalled");

  // A response must be held until the consumer takes it.
  property p_response_held;
    @(posedge clk) disable iff (!rst_n)
      (rsp_valid && !rsp_ready) |=> rsp_valid;
  endproperty
  a_response_held : assert property (p_response_held)
    else $error("bram_ctrl: rsp_valid was withdrawn before rsp_ready");
`endif

endmodule

`default_nettype wire
