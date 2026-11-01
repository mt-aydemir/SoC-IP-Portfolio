//=============================================================================
// Module      : spi_master
// Category    : peripherals
// Description : SPI master with run-time mode and bit order, a programmable
//               SCLK rate and multi-word chip-select framing.
//
// Each word handed in on the s_ stream is exchanged full duplex: DATA_WIDTH
// bits go out on mosi while DATA_WIDTH bits come in on miso, and the received
// word is presented on m_valid / m_data when the exchange completes.
//
// Mode (run time, sampled while idle)
//   cpol       SCLK idle level.
//   cpha = 0   data is set up before the leading edge, sampled on the leading
//              edge and changed on the trailing edge; the first bit is on mosi
//              half a period before the first edge.
//   cpha = 1   data changes on the leading edge and is sampled on the
//              trailing edge.
//   lsb_first  bit order on the wire.
//
// Every word produces exactly 2 * DATA_WIDTH SCLK edges, half a period apart,
// and SCLK finishes at its idle level. The first edge comes half a period
// after cs_n falls (or after the previous word ended, for a continued frame),
// and the frame holds cs_n low for half a period after the last edge.
//
// Framing
//   s_last marks the final word of a chip-select frame. After it cs_n rises
//   and stays high for at least half a period before the next frame. After a
//   word without s_last, cs_n stays low and SCLK idles until the next word,
//   so a command, an address and a data phase can be sent as one frame
//   however long the host takes to supply them.
//
// Timing
//   clk_div is the SCLK half period in clk cycles, >= 1. miso is sampled on
//   the clk edge that produces the sampling SCLK edge, so the slave's output
//   delay plus the board round trip must fit in one SCLK half period. miso
//   is not synchronised: it is synchronous to the SCLK this block generates,
//   and is timed as such (see scripts/spi_master.sdc).
//
// Parameters
//   DATA_WIDTH  Bits per word. >= 2.
//   DIV_WIDTH   Width of clk_div. >= 1.
//
// Latency     : (2 * DATA_WIDTH + 2) * clk_div cycles per word, plus one half
//               period of cs_n high time after the last word of a frame
// Reset       : asynchronous assertion, synchronous release, active low.
//               cs_n high, SCLK at cpol, idle.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module spi_master #(
    parameter int unsigned DATA_WIDTH = 8,
    parameter int unsigned DIV_WIDTH  = 8
) (
    input  wire                   clk,
    input  wire                   rst_n,

    // Configuration; change only while busy is low
    input  wire                   cpol,
    input  wire                   cpha,
    input  wire                   lsb_first,
    input  wire  [DIV_WIDTH-1:0]  clk_div,

    // Words to send
    input  wire                   s_valid,
    output logic                  s_ready,
    input  wire  [DATA_WIDTH-1:0] s_data,
    input  wire                   s_last,

    // Words received, one pulse per word
    output logic                  m_valid,
    output logic [DATA_WIDTH-1:0] m_data,

    output logic                  busy,

    // SPI bus
    output logic                  sclk,
    output logic                  mosi,
    input  wire                   miso,
    output logic                  cs_n
);

  localparam int unsigned EDGES      = 2 * DATA_WIDTH;
  localparam int unsigned EDGE_WIDTH = $clog2(EDGES);

  typedef enum logic [2:0] {
    S_IDLE,       // cs_n high
    S_SETUP,      // cs_n low, half a period before the first edge
    S_SHIFT,      // generating edges
    S_FINISH,     // half a period after the last edge
    S_HOLD,       // cs_n low between the words of a frame
    S_CS_HIGH     // minimum cs_n high time
  } state_t;

  state_t                state;
  logic [DIV_WIDTH-1:0]  count;
  logic [EDGE_WIDTH-1:0] edge_index;
  logic [DATA_WIDTH-1:0] tx_shift;
  logic [DATA_WIDTH-1:0] rx_shift;
  logic                  last_q;

  logic tick;
  assign tick = (count == '0);

  // The bit on the wire is the end of the shift register the order selects;
  // shifting moves the next one into its place.
  function automatic logic out_bit(input logic [DATA_WIDTH-1:0] word,
                                   input logic lsb);
    out_bit = lsb ? word[0] : word[DATA_WIDTH-1];
  endfunction

  function automatic logic [DATA_WIDTH-1:0] shift_out(
      input logic [DATA_WIDTH-1:0] word, input logic lsb);
    shift_out = lsb ? {1'b0, word[DATA_WIDTH-1:1]}
                    : {word[DATA_WIDTH-2:0], 1'b0};
  endfunction

  function automatic logic [DATA_WIDTH-1:0] shift_in(
      input logic [DATA_WIDTH-1:0] word, input logic bit_in, input logic lsb);
    shift_in = lsb ? {bit_in, word[DATA_WIDTH-1:1]}
                   : {word[DATA_WIDTH-2:0], bit_in};
  endfunction

  logic accept;
  assign s_ready = (state == S_IDLE) || (state == S_HOLD);
  assign accept  = s_valid && s_ready;
  assign busy    = (state != S_IDLE);

  // An edge with an even index is a leading edge. With cpha = 0 leading edges
  // sample and trailing edges shift; with cpha = 1 it is the other way round.
  logic leading;
  logic sample_edge;
  assign leading     = !edge_index[0];
  assign sample_edge = (leading != cpha);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_IDLE;
      count      <= '0;
      edge_index <= '0;
      tx_shift   <= '0;
      rx_shift   <= '0;
      last_q     <= 1'b0;
      m_valid    <= 1'b0;
      m_data     <= '0;
      sclk       <= 1'b0;
      mosi       <= 1'b0;
      cs_n       <= 1'b1;
    end else begin
      m_valid <= 1'b0;

      if (accept) begin
        // Load the word. With cpha = 0 its first bit goes on the wire now,
        // a half period ahead of the first (sampling) edge.
        last_q     <= s_last;
        rx_shift   <= '0;
        edge_index <= '0;
        count      <= clk_div - DIV_WIDTH'(1);
        cs_n       <= 1'b0;
        sclk       <= cpol;
        state      <= S_SETUP;
        if (!cpha) begin
          mosi     <= out_bit(s_data, lsb_first);
          tx_shift <= shift_out(s_data, lsb_first);
        end else begin
          tx_shift <= s_data;
        end
      end else if (state == S_IDLE) begin
        sclk <= cpol;
      end else if (state == S_HOLD) begin
        // cs_n held low, SCLK idle, waiting for the next word of the frame
      end else if (!tick) begin
        count <= count - DIV_WIDTH'(1);
      end else begin
        count <= clk_div - DIV_WIDTH'(1);
        unique case (state)
          S_SETUP, S_SHIFT: begin
            sclk <= ~sclk;
            if (sample_edge) begin
              rx_shift <= shift_in(rx_shift, miso, lsb_first);
            end else if (cpha || edge_index != EDGE_WIDTH'(EDGES - 1)) begin
              // Shift edge. With cpha = 0 the last edge has nothing left to
              // shift; with cpha = 1 every leading edge puts out a bit.
              mosi     <= out_bit(tx_shift, lsb_first);
              tx_shift <= shift_out(tx_shift, lsb_first);
            end

            if (state == S_SETUP) begin
              state <= S_SHIFT;
            end
            if (edge_index == EDGE_WIDTH'(EDGES - 1)) begin
              state <= S_FINISH;
            end else begin
              edge_index <= edge_index + EDGE_WIDTH'(1);
            end
          end

          S_FINISH: begin
            m_valid <= 1'b1;
            m_data  <= rx_shift;
            if (last_q) begin
              cs_n  <= 1'b1;
              state <= S_CS_HIGH;
            end else begin
              state <= S_HOLD;
            end
          end

          S_CS_HIGH: state <= S_IDLE;

          default: state <= S_IDLE;
        endcase
      end
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DATA_WIDTH < 2) begin
      $fatal(1, "spi_master: DATA_WIDTH must be >= 2 (got %0d)", DATA_WIDTH);
    end
    if (DIV_WIDTH < 1) begin
      $fatal(1, "spi_master: DIV_WIDTH must be >= 1 (got %0d)", DIV_WIDTH);
    end
  end

  property p_div_nonzero;
    @(posedge clk) disable iff (!rst_n) accept |-> (clk_div != '0);
  endproperty
  a_div_nonzero : assert property (p_div_nonzero)
    else $error("spi_master: clk_div must be >= 1");

  // SCLK is at its idle level whenever the slave is deselected.
  property p_idle_sclk;
    @(posedge clk) disable iff (!rst_n)
      (cs_n && $past(cs_n) && state == S_IDLE && $stable(cpol)) |-> (sclk == cpol);
  endproperty
  a_idle_sclk : assert property (p_idle_sclk)
    else $error("spi_master: SCLK not at cpol while deselected");
`endif

endmodule

`default_nettype wire
