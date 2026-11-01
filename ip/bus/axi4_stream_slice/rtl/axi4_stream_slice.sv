//=============================================================================
// Module      : axi4_stream_slice
// Category    : bus
// Description : AMBA AXI4-Stream register slice: breaks the forward path, the
//               backward (TREADY) path, or both, without losing throughput.
//
// A long stream - across a chip, between two blocks that each close timing
// on their own - fails timing on one of two paths: TVALID and the payload
// travelling forward, or TREADY travelling back. A register slice cuts one or
// both. Every beat is delivered exactly once and in order, with every
// sideband intact; only its timing changes.
//
// MODE selects the cut:
//   0  BYPASS   Wires. Lets a slice be configured away without editing the
//               design around it.
//   1  FORWARD  TVALID and the payload are registered; TREADY passes back
//               combinationally. Full throughput, one cycle of latency.
//   2  REVERSE  TREADY is registered; TVALID and the payload pass forward
//               combinationally, from the input or from a one-beat skid
//               register when the output stalled. Full throughput, no
//               latency.
//   3  FULL     Both registered: a skid register in front of an output
//               register. Full throughput, one cycle of latency, and no
//               combinational path from any input to any output.
//   4  LIGHT    Both registered with a single register: one beat every two
//               cycles at most. The smallest slice that cuts both paths,
//               for streams that never run at full rate.
//
// Every AXI4-Stream signal is carried: TDATA, TSTRB, TKEEP, TLAST, TID, TDEST
// and TUSER. A design that does not use one ties its input to a constant and
// leaves the output open; synthesis removes the constant register.
//
// Parameters
//   MODE        0 to 4, as above.
//   DATA_WIDTH  TDATA width, a multiple of 8. TSTRB and TKEEP are
//               DATA_WIDTH/8.
//   ID_WIDTH    TID width, >= 1.
//   DEST_WIDTH  TDEST width, >= 1.
//   USER_WIDTH  TUSER width, >= 1.
//
// Latency     : MODE 1, 3 and 4: one cycle. MODE 0 and 2: none.
// Reset       : asynchronous assertion, synchronous release, active low.
//               Empty: m_axis_tvalid low.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module axi4_stream_slice #(
    parameter int unsigned MODE       = 3,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned ID_WIDTH   = 1,
    parameter int unsigned DEST_WIDTH = 1,
    parameter int unsigned USER_WIDTH = 1
) (
    input  wire                     clk,
    input  wire                     rst_n,

    // Subordinate (input) stream
    input  wire                     s_axis_tvalid,
    output logic                    s_axis_tready,
    input  wire  [DATA_WIDTH-1:0]   s_axis_tdata,
    input  wire  [DATA_WIDTH/8-1:0] s_axis_tstrb,
    input  wire  [DATA_WIDTH/8-1:0] s_axis_tkeep,
    input  wire                     s_axis_tlast,
    input  wire  [ID_WIDTH-1:0]     s_axis_tid,
    input  wire  [DEST_WIDTH-1:0]   s_axis_tdest,
    input  wire  [USER_WIDTH-1:0]   s_axis_tuser,

    // Manager (output) stream
    output logic                    m_axis_tvalid,
    input  wire                     m_axis_tready,
    output logic [DATA_WIDTH-1:0]   m_axis_tdata,
    output logic [DATA_WIDTH/8-1:0] m_axis_tstrb,
    output logic [DATA_WIDTH/8-1:0] m_axis_tkeep,
    output logic                    m_axis_tlast,
    output logic [ID_WIDTH-1:0]     m_axis_tid,
    output logic [DEST_WIDTH-1:0]   m_axis_tdest,
    output logic [USER_WIDTH-1:0]   m_axis_tuser
);

  localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8;
  localparam int unsigned WIDTH      = DATA_WIDTH + 2 * STRB_WIDTH + 1
                                     + ID_WIDTH + DEST_WIDTH + USER_WIDTH;

  localparam int unsigned MODE_BYPASS  = 0;
  localparam int unsigned MODE_FORWARD = 1;
  localparam int unsigned MODE_REVERSE = 2;
  localparam int unsigned MODE_FULL    = 3;
  localparam int unsigned MODE_LIGHT   = 4;

  // The payload travels as one vector, so each mode is written once.
  logic [WIDTH-1:0] s_payload;
  logic [WIDTH-1:0] m_payload;

  assign s_payload = {s_axis_tdata, s_axis_tstrb, s_axis_tkeep, s_axis_tlast,
                      s_axis_tid, s_axis_tdest, s_axis_tuser};
  assign {m_axis_tdata, m_axis_tstrb, m_axis_tkeep, m_axis_tlast,
          m_axis_tid, m_axis_tdest, m_axis_tuser} = m_payload;

  generate
    if (MODE == MODE_BYPASS) begin : g_bypass

      assign m_axis_tvalid = s_axis_tvalid;
      assign s_axis_tready = m_axis_tready;
      assign m_payload     = s_payload;

    end else if (MODE == MODE_FORWARD) begin : g_forward

      logic             valid_q;
      logic [WIDTH-1:0] data_q;

      // The register can load when it is empty or being emptied this cycle.
      assign s_axis_tready = !valid_q || m_axis_tready;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          valid_q <= 1'b0;
          data_q  <= '0;
        end else if (s_axis_tready) begin
          valid_q <= s_axis_tvalid;
          if (s_axis_tvalid) data_q <= s_payload;
        end
      end

      assign m_axis_tvalid = valid_q;
      assign m_payload     = data_q;

    end else if (MODE == MODE_REVERSE) begin : g_reverse

      // The skid register catches the beat accepted in the cycle the output
      // stalled: TREADY was already high, registered from the cycle before.
      logic             skid_q;
      logic [WIDTH-1:0] skid_data;

      assign s_axis_tready = !skid_q;
      assign m_axis_tvalid = skid_q || s_axis_tvalid;
      assign m_payload     = skid_q ? skid_data : s_payload;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          skid_q    <= 1'b0;
          skid_data <= '0;
        end else if (skid_q) begin
          if (m_axis_tready) skid_q <= 1'b0;
        end else if (s_axis_tvalid && !m_axis_tready) begin
          skid_q    <= 1'b1;
          skid_data <= s_payload;
        end
      end

    end else if (MODE == MODE_FULL) begin : g_full

      logic             valid_q, skid_q;
      logic [WIDTH-1:0] data_q, skid_data;
      logic             load;

      assign s_axis_tready = !skid_q;
      assign load          = !valid_q || m_axis_tready;

      // The output register loads whenever it is free: from the skid
      // register if that holds a beat (TREADY was low, so nothing new is
      // arriving), otherwise straight from the input. If it is not free, an
      // accepted beat goes to the skid register, which then drops TREADY.
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          valid_q   <= 1'b0;
          data_q    <= '0;
          skid_q    <= 1'b0;
          skid_data <= '0;
        end else if (load) begin
          if (skid_q) begin
            valid_q <= 1'b1;
            data_q  <= skid_data;
            skid_q  <= 1'b0;
          end else begin
            valid_q <= s_axis_tvalid;
            if (s_axis_tvalid) data_q <= s_payload;
          end
        end else if (s_axis_tvalid && s_axis_tready) begin
          skid_q    <= 1'b1;
          skid_data <= s_payload;
        end
      end

      assign m_axis_tvalid = valid_q;
      assign m_payload     = data_q;

    end else begin : g_light

      logic             full_q;
      logic [WIDTH-1:0] data_q;

      assign s_axis_tready = !full_q;
      assign m_axis_tvalid = full_q;
      assign m_payload     = data_q;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          full_q <= 1'b0;
          data_q <= '0;
        end else if (full_q) begin
          if (m_axis_tready) full_q <= 1'b0;
        end else if (s_axis_tvalid) begin
          full_q <= 1'b1;
          data_q <= s_payload;
        end
      end

    end
  endgenerate

  //---------------------------------------------------------------------------
  // Protocol checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (MODE > MODE_LIGHT) begin
      $fatal(1, "axi4_stream_slice: MODE must be 0 to 4 (got %0d)", MODE);
    end
    if (DATA_WIDTH < 8 || DATA_WIDTH % 8 != 0) begin
      $fatal(1, "axi4_stream_slice: DATA_WIDTH must be a multiple of 8 (got %0d)",
             DATA_WIDTH);
    end
    if (ID_WIDTH < 1 || DEST_WIDTH < 1 || USER_WIDTH < 1) begin
      $fatal(1, "axi4_stream_slice: ID_WIDTH, DEST_WIDTH and USER_WIDTH must be >= 1");
    end
  end

  // Both sides: once TVALID is high, it and the payload hold until TREADY.
  property p_input_held;
    @(posedge clk) disable iff (!rst_n)
      (s_axis_tvalid && !s_axis_tready) |=> (s_axis_tvalid && $stable(s_payload));
  endproperty
  a_input_held : assert property (p_input_held)
    else $error("axi4_stream_slice: input beat changed before TREADY");

  property p_output_held;
    @(posedge clk) disable iff (!rst_n)
      (m_axis_tvalid && !m_axis_tready) |=> (m_axis_tvalid && $stable(m_payload));
  endproperty
  a_output_held : assert property (p_output_held)
    else $error("axi4_stream_slice: output beat changed before TREADY");
`endif

endmodule

`default_nettype wire
