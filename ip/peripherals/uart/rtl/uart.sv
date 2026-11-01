//=============================================================================
// Module      : uart
// Category    : peripherals
// Description : Full-duplex asynchronous serial transmitter and receiver with
//               a run-time bit period, optional parity and error reporting.
//
// Frame: one start bit (low), DATA_BITS data bits least significant first, an
// optional parity bit, then STOP_BITS stop bits (high). The line idles high.
//
// The bit period is an input, clks_per_bit, rather than a parameter derived
// from a clock frequency and a baud rate. That keeps the block independent
// of the system clock - the same netlist serves every baud rate - and leaves
// the rounding of CLK_HZ / BAUD, and its error budget, to the integrator who
// knows both numbers. It must be at least 4 and must not change while either
// direction is busy.
//
// Transmitter
//   A word is accepted on s_valid && s_ready and shifted out immediately.
//   s_ready is low for the whole frame. Back-to-back words are separated by
//   one extra clock of stop level, so the stop period is STOP_BITS bit times
//   plus one clock, which every receiver accepts.
//
// Receiver
//   rxd is synchronised, then a falling edge starts a frame. The start bit is
//   sampled again half a bit later and the frame is abandoned if the line has
//   returned high, so a glitch shorter than half a bit is not a character.
//   Every later bit is sampled at its centre. Only the first stop bit is
//   checked; a receiver that demanded both would reject a transmitter that
//   sends one and a half.
//
//   A completed character is offered on m_valid / m_data with its parity and
//   framing errors alongside, and is held until m_ready. A character that
//   completes while the previous one is still held is dropped and rx_overrun
//   pulses: the old character is kept because it is the one software is
//   already reading.
//
//   After a framing error the receiver waits for the line to return high
//   before looking for the next start bit. Without that, a break - the line
//   held low for longer than a frame - would be received as an endless run of
//   zero characters with framing errors.
//
// Parameters
//   DATA_BITS    5 to 9.
//   PARITY       0 none, 1 even, 2 odd.
//   STOP_BITS    1 or 2 (transmitted; the receiver checks one).
//   DIV_WIDTH    Width of clks_per_bit. >= 3.
//   SYNC_STAGES  rxd synchroniser depth. >= 2.
//
// Latency     : txd starts one clock after acceptance; m_valid rises at the
//               centre of the first stop bit plus the synchroniser delay
// Reset       : asynchronous assertion, synchronous release, active low.
//               txd high, both directions idle.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module uart #(
    parameter int unsigned DATA_BITS   = 8,
    parameter int unsigned PARITY      = 0,
    parameter int unsigned STOP_BITS   = 1,
    parameter int unsigned DIV_WIDTH   = 16,
    parameter int unsigned SYNC_STAGES = 2
) (
    input  wire                  clk,
    input  wire                  rst_n,

    // Bit period in clk cycles, >= 4
    input  wire  [DIV_WIDTH-1:0] clks_per_bit,

    // Transmit stream
    input  wire                  s_valid,
    output logic                 s_ready,
    input  wire  [DATA_BITS-1:0] s_data,
    output logic                 txd,

    // Receive stream
    output logic                 m_valid,
    input  wire                  m_ready,
    output logic [DATA_BITS-1:0] m_data,
    output logic                 m_parity_err,
    output logic                 m_frame_err,
    output logic                 rx_overrun,
    input  wire                  rxd
);

  localparam int unsigned PARITY_BITS = (PARITY != 0) ? 1 : 0;
  localparam int unsigned FRAME_BITS  = 1 + DATA_BITS + PARITY_BITS + STOP_BITS;
  localparam int unsigned COUNT_WIDTH = $clog2(FRAME_BITS);

  // Parity of a data word as transmitted: even makes the total number of ones
  // in data plus parity even, odd makes it odd.
  function automatic logic parity_of(input logic [DATA_BITS-1:0] data);
    parity_of = (PARITY == 2) ? ~(^data) : ^data;
  endfunction

  //===========================================================================
  // Transmitter
  //===========================================================================
  logic [FRAME_BITS-1:0]  tx_frame;
  logic [FRAME_BITS-1:0]  tx_shift;
  logic [DIV_WIDTH-1:0]   tx_count;
  logic [COUNT_WIDTH-1:0] tx_bits_left;
  logic                   tx_busy;

  // Start bit in bit 0, stop bits at the top; everything not assigned is a
  // stop bit.
  always_comb begin
    tx_frame              = '1;
    tx_frame[0]           = 1'b0;
    tx_frame[DATA_BITS:1] = s_data;
    if (PARITY != 0) begin
      tx_frame[DATA_BITS+1] = parity_of(s_data);
    end
  end

  assign s_ready = !tx_busy;

  // The line is the bottom of the shift register, which resets and refills
  // with ones, so txd is a flop output and idles high.
  assign txd = tx_shift[0];

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_shift     <= '1;
      tx_count     <= '0;
      tx_bits_left <= '0;
      tx_busy      <= 1'b0;
    end else if (!tx_busy) begin
      if (s_valid) begin
        tx_shift     <= tx_frame;
        tx_count     <= clks_per_bit - DIV_WIDTH'(1);
        tx_bits_left <= COUNT_WIDTH'(FRAME_BITS - 1);
        tx_busy      <= 1'b1;
      end
    end else if (tx_count != '0) begin
      tx_count <= tx_count - DIV_WIDTH'(1);
    end else if (tx_bits_left == '0) begin
      tx_busy <= 1'b0;                // the last stop bit has had its period
    end else begin
      tx_shift     <= {1'b1, tx_shift[FRAME_BITS-1:1]};
      tx_count     <= clks_per_bit - DIV_WIDTH'(1);
      tx_bits_left <= tx_bits_left - COUNT_WIDTH'(1);
    end
  end

  //===========================================================================
  // Receiver
  //===========================================================================
  logic rx_sync;

  cdc_sync_2ff #(
      .WIDTH       (1),
      .STAGES      (SYNC_STAGES),
      .RESET_VALUE (1'b1)             // idle level, so reset is not a start bit
  ) u_rxd_sync (
      .clk     (clk),
      .rst_n   (rst_n),
      .d_async (rxd),
      .q_sync  (rx_sync)
  );

  typedef enum logic [2:0] {
    RX_IDLE,
    RX_START,
    RX_DATA,
    RX_PARITY,
    RX_STOP,
    RX_WAIT_HIGH
  } rx_state_t;

  rx_state_t              rx_state;
  logic [DIV_WIDTH-1:0]   rx_count;
  logic [COUNT_WIDTH-1:0] rx_index;
  logic [DATA_BITS-1:0]   rx_shift;
  logic                   rx_parity_bad;

  logic rx_tick;
  assign rx_tick = (rx_count == '0);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_state      <= RX_IDLE;
      rx_count      <= '0;
      rx_index      <= '0;
      rx_shift      <= '0;
      rx_parity_bad <= 1'b0;
      m_valid       <= 1'b0;
      m_data        <= '0;
      m_parity_err  <= 1'b0;
      m_frame_err   <= 1'b0;
      rx_overrun    <= 1'b0;
    end else begin
      rx_overrun <= 1'b0;

      if (m_valid && m_ready) begin
        m_valid <= 1'b0;
      end

      if (rx_state != RX_IDLE && rx_state != RX_WAIT_HIGH && !rx_tick) begin
        rx_count <= rx_count - DIV_WIDTH'(1);
      end else begin
        unique case (rx_state)
          RX_IDLE: begin
            if (!rx_sync) begin
              rx_state <= RX_START;
              rx_count <= (clks_per_bit >> 1) - DIV_WIDTH'(1);
            end
          end

          RX_START: begin
            if (!rx_sync) begin
              rx_state <= RX_DATA;
              rx_index <= '0;
              rx_count <= clks_per_bit - DIV_WIDTH'(1);
            end else begin
              rx_state <= RX_IDLE;    // glitch, not a start bit
            end
          end

          RX_DATA: begin
            rx_shift <= {rx_sync, rx_shift[DATA_BITS-1:1]};
            rx_count <= clks_per_bit - DIV_WIDTH'(1);
            if (rx_index == COUNT_WIDTH'(DATA_BITS - 1)) begin
              rx_state <= (PARITY != 0) ? RX_PARITY : RX_STOP;
            end else begin
              rx_index <= rx_index + COUNT_WIDTH'(1);
            end
          end

          RX_PARITY: begin
            rx_parity_bad <= (rx_sync != parity_of(rx_shift));
            rx_count      <= clks_per_bit - DIV_WIDTH'(1);
            rx_state      <= RX_STOP;
          end

          RX_STOP: begin
            rx_state <= rx_sync ? RX_IDLE : RX_WAIT_HIGH;
            if (m_valid && !m_ready) begin
              rx_overrun <= 1'b1;     // keep the held character
            end else begin
              m_valid      <= 1'b1;
              m_data       <= rx_shift;
              m_parity_err <= (PARITY != 0) && rx_parity_bad;
              m_frame_err  <= !rx_sync;
            end
          end

          RX_WAIT_HIGH: begin
            if (rx_sync) begin
              rx_state <= RX_IDLE;
            end
          end

          default: rx_state <= RX_IDLE;
        endcase
      end
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DATA_BITS < 5 || DATA_BITS > 9) begin
      $fatal(1, "uart: DATA_BITS must be 5 to 9 (got %0d)", DATA_BITS);
    end
    if (PARITY > 2) begin
      $fatal(1, "uart: PARITY must be 0, 1 or 2 (got %0d)", PARITY);
    end
    if (STOP_BITS < 1 || STOP_BITS > 2) begin
      $fatal(1, "uart: STOP_BITS must be 1 or 2 (got %0d)", STOP_BITS);
    end
    if (DIV_WIDTH < 3) begin
      $fatal(1, "uart: DIV_WIDTH must be >= 3 (got %0d)", DIV_WIDTH);
    end
    if (SYNC_STAGES < 2) begin
      $fatal(1, "uart: SYNC_STAGES must be >= 2 (got %0d)", SYNC_STAGES);
    end
  end

  // No frame may start with a bit period too short to find the bit centre.
  property p_min_period;
    @(posedge clk) disable iff (!rst_n)
      ((s_valid && s_ready) || (rx_state == RX_IDLE && !rx_sync))
        |-> (clks_per_bit >= DIV_WIDTH'(4));
  endproperty
  a_min_period : assert property (p_min_period)
    else $error("uart: clks_per_bit must be >= 4 (got %0d)", clks_per_bit);
`endif

endmodule

`default_nettype wire
