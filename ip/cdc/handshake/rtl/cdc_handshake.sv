//=============================================================================
// Module      : cdc_handshake
// Category    : cdc
// Description : Transfers a multi-bit value between clock domains using a
//               four-phase request/acknowledge handshake.
//
// A multi-bit value must never cross a clock domain boundary through a bank of
// synchronisers: each bit resolves independently, so the destination can
// sample a combination that never existed at the source.
//
// This block solves that by never letting the data path cross asynchronously
// at all. Only two single-bit control signals are synchronised - a request and
// an acknowledge - and the payload is held in a source-domain register that is
// guaranteed stable for the whole time the destination is allowed to read it.
// The destination therefore samples a static value, and no synchroniser is
// needed on the data path.
//
// Four-phase sequence:
//
//   1. Source latches the payload and raises req.
//   2. Destination sees req through a synchroniser, captures the payload and
//      presents it on its own stream interface.
//   3. Once the destination consumer accepts the word, destination raises ack.
//   4. Source sees ack, drops req; destination sees req drop and drops ack;
//      the source is then free to accept the next word.
//
// Choose this block over fifo_async when transfers are occasional and buffering
// is not wanted: it costs two flip-flop chains and a register rather than a
// dual-port memory. For continuous streaming, use fifo_async - a handshake
// pays the full round-trip latency on every single word.
//
// Parameters
//   DATA_WIDTH  Payload width in bits.
//   STAGES      Synchroniser depth used in both directions.
//
// Latency     : STAGES dst cycles from req to dst_valid; a full transfer costs
//               roughly 2*STAGES cycles in each domain
// Throughput  : one word per round trip - not a streaming interface
// Reset       : asynchronous assertion, synchronous release, active low, one
//               reset per domain
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module cdc_handshake #(
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned STAGES     = 2
) (
    // Source clock domain
    input  wire                   src_clk,
    input  wire                   src_rst_n,
    input  wire                   src_valid,
    output logic                  src_ready,
    input  wire  [DATA_WIDTH-1:0] src_data,

    // Destination clock domain
    input  wire                   dst_clk,
    input  wire                   dst_rst_n,
    output logic                  dst_valid,
    input  wire                   dst_ready,
    output logic [DATA_WIDTH-1:0] dst_data
);

  //---------------------------------------------------------------------------
  // Source domain state
  //---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    SRC_IDLE,      // ready for a new word
    SRC_REQUEST,   // req raised, waiting for ack
    SRC_RECOVER    // ack seen, req dropped, waiting for ack to fall
  } src_state_e;

  src_state_e            src_state_q;
  logic [DATA_WIDTH-1:0] payload_q;
  logic                  src_req_q;
  logic                  src_ack_sync;

  assign src_ready = (src_state_q == SRC_IDLE);

  always_ff @(posedge src_clk or negedge src_rst_n) begin
    if (!src_rst_n) begin
      src_state_q <= SRC_IDLE;
      src_req_q   <= 1'b0;
      payload_q   <= '0;
    end else begin
      unique case (src_state_q)
        SRC_IDLE: begin
          if (src_valid) begin
            // The payload register is written only here, and only while req is
            // low. That is what guarantees it is stable for the whole window
            // in which the destination is permitted to read it.
            payload_q   <= src_data;
            src_req_q   <= 1'b1;
            src_state_q <= SRC_REQUEST;
          end
        end

        SRC_REQUEST: begin
          if (src_ack_sync) begin
            src_req_q   <= 1'b0;
            src_state_q <= SRC_RECOVER;
          end
        end

        SRC_RECOVER: begin
          // Wait for the acknowledge to fall before accepting the next word,
          // otherwise the next request would be acknowledged by the tail of
          // the previous transfer.
          if (!src_ack_sync) begin
            src_state_q <= SRC_IDLE;
          end
        end

        default: begin
          src_state_q <= SRC_IDLE;
        end
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // Request: source -> destination
  //---------------------------------------------------------------------------
  logic dst_req_sync;

  cdc_sync_2ff #(
      .WIDTH       (1),
      .STAGES      (STAGES),
      .RESET_VALUE (1'b0)
  ) u_sync_req (
      .clk     (dst_clk),
      .rst_n   (dst_rst_n),
      .d_async (src_req_q),
      .q_sync  (dst_req_sync)
  );

  //---------------------------------------------------------------------------
  // Destination domain state
  //---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    DST_IDLE,      // waiting for a request
    DST_PRESENT,   // payload captured and offered to the consumer
    DST_ACK        // consumer took it, ack raised until req falls
  } dst_state_e;

  dst_state_e dst_state_q;
  logic       dst_ack_q;

  always_ff @(posedge dst_clk or negedge dst_rst_n) begin
    if (!dst_rst_n) begin
      dst_state_q <= DST_IDLE;
      dst_ack_q   <= 1'b0;
      dst_valid   <= 1'b0;
      dst_data    <= '0;
    end else begin
      unique case (dst_state_q)
        DST_IDLE: begin
          if (dst_req_sync) begin
            // payload_q has been stable since before req was synchronised, so
            // this crosses the boundary as a static value, not as a
            // simultaneously changing bus.
            dst_data    <= payload_q;
            dst_valid   <= 1'b1;
            dst_state_q <= DST_PRESENT;
          end
        end

        DST_PRESENT: begin
          if (dst_ready) begin
            dst_valid   <= 1'b0;
            dst_ack_q   <= 1'b1;
            dst_state_q <= DST_ACK;
          end
        end

        DST_ACK: begin
          if (!dst_req_sync) begin
            dst_ack_q   <= 1'b0;
            dst_state_q <= DST_IDLE;
          end
        end

        default: begin
          dst_state_q <= DST_IDLE;
        end
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // Acknowledge: destination -> source
  //---------------------------------------------------------------------------
  cdc_sync_2ff #(
      .WIDTH       (1),
      .STAGES      (STAGES),
      .RESET_VALUE (1'b0)
  ) u_sync_ack (
      .clk     (src_clk),
      .rst_n   (src_rst_n),
      .d_async (dst_ack_q),
      .q_sync  (src_ack_sync)
  );

  //---------------------------------------------------------------------------
  // Elaboration-time checks and protocol assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DATA_WIDTH < 1) begin
      $fatal(1, "cdc_handshake: DATA_WIDTH must be >= 1 (got %0d)", DATA_WIDTH);
    end
    if (STAGES < 2) begin
      $fatal(1, {"cdc_handshake: STAGES must be >= 2 (got %0d); a single ",
                 "flop provides no metastability resolution time"}, STAGES);
    end
  end

  // Source stream contract: the payload must be stable while stalled.
  property p_src_stable;
    @(posedge src_clk) disable iff (!src_rst_n)
      (src_valid && !src_ready) |=> $stable(src_data);
  endproperty
  a_src_stable : assert property (p_src_stable)
    else $error("cdc_handshake: src_data changed while the transfer was stalled");

  // The payload register must not move while the destination may be reading it.
  property p_payload_held;
    @(posedge src_clk) disable iff (!src_rst_n)
      src_req_q |=> $stable(payload_q);
  endproperty
  a_payload_held : assert property (p_payload_held)
    else $error("cdc_handshake: payload changed while the request was raised");

  // Destination stream contract: valid is held until the consumer accepts.
  property p_dst_valid_held;
    @(posedge dst_clk) disable iff (!dst_rst_n)
      (dst_valid && !dst_ready) |=> dst_valid;
  endproperty
  a_dst_valid_held : assert property (p_dst_valid_held)
    else $error("cdc_handshake: dst_valid was withdrawn before dst_ready");
`endif

endmodule

`default_nettype wire
