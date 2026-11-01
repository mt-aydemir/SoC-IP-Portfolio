//=============================================================================
// Module      : gpio
// Category    : peripherals
// Description : General-purpose I/O port with per-pin direction, atomic
//               set/clear, synchronised inputs and edge interrupts.
//
// Each of the WIDTH pins is independently an input or an output. The block
// presents the three signals a pad needs - pin_out, pin_oe and pin_in - and
// leaves the tri-state buffer itself to the pad ring, so nothing here is
// technology specific.
//
// Inputs are asynchronous to clk and pass through a synchroniser before any
// logic sees them. Each pin is synchronised on its own: the pins are
// independent signals, and IN is a set of independent samples, not a coherent
// word. Software that needs several pins sampled together must arrange that
// externally.
//
// Register map (addr, combinational read)
//   0  OUT      rw  output value of every pin
//   1  DIR      rw  1 = output (pin_oe high), 0 = input
//   2  IN       ro  synchronised pin value, outputs included
//   3  OUT_SET  wo  OUT |=  wr_data   (reads 0)
//   4  OUT_CLR  wo  OUT &= ~wr_data   (reads 0)
//   5  RISE_EN  rw  interrupt on a rising edge of the pin
//   6  FALL_EN  rw  interrupt on a falling edge of the pin
//   7  STATUS   rw1c  latched edge events; write 1 to clear
//
// OUT_SET and OUT_CLR exist so that two agents - an interrupt handler and the
// main loop, say - can each drive their own pins without a read-modify-write
// race on OUT.
//
// pin_out is the OUT register unmasked by DIR. The pad only drives when
// pin_oe is high, and keeping the two separate means software can preload a
// value before turning a pin into an output, which avoids a glitch to the
// reset value on the pad.
//
// An edge event that arrives in the same cycle as a write-1-to-clear of the
// same bit wins: the bit stays set. Losing an interrupt is worse than taking
// a spurious one.
//
// Parameters
//   WIDTH        Number of pins. 1 to 32.
//   SYNC_STAGES  Input synchroniser depth. >= 2.
//
// Latency     : writes take effect on the next edge; IN lags the pad by
//               SYNC_STAGES cycles, an edge event by one more
// Reset       : asynchronous assertion, synchronous release, active low.
//               All pins inputs, OUT zero, interrupts disabled and clear.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module gpio #(
    parameter int unsigned WIDTH       = 8,
    parameter int unsigned SYNC_STAGES = 2
) (
    input  wire              clk,
    input  wire              rst_n,

    // Register port
    input  wire  [2:0]       addr,
    input  wire              wr_en,
    input  wire  [WIDTH-1:0] wr_data,
    output logic [WIDTH-1:0] rd_data,

    // Pads
    input  wire  [WIDTH-1:0] pin_in,
    output logic [WIDTH-1:0] pin_out,
    output logic [WIDTH-1:0] pin_oe,

    // Level interrupt: any enabled event latched in STATUS
    output logic             irq
);

  localparam logic [2:0] ADDR_OUT     = 3'd0;
  localparam logic [2:0] ADDR_DIR     = 3'd1;
  localparam logic [2:0] ADDR_IN      = 3'd2;
  localparam logic [2:0] ADDR_OUT_SET = 3'd3;
  localparam logic [2:0] ADDR_OUT_CLR = 3'd4;
  localparam logic [2:0] ADDR_RISE_EN = 3'd5;
  localparam logic [2:0] ADDR_FALL_EN = 3'd6;
  localparam logic [2:0] ADDR_STATUS  = 3'd7;

  logic [WIDTH-1:0] out_q;
  logic [WIDTH-1:0] dir_q;
  logic [WIDTH-1:0] rise_en_q;
  logic [WIDTH-1:0] fall_en_q;
  logic [WIDTH-1:0] status_q;

  //---------------------------------------------------------------------------
  // Input synchroniser and edge detection
  //---------------------------------------------------------------------------
  logic [WIDTH-1:0] in_sync;
  logic [WIDTH-1:0] in_prev;

  cdc_sync_2ff #(
      .WIDTH  (WIDTH),
      .STAGES (SYNC_STAGES)
  ) u_sync (
      .clk     (clk),
      .rst_n   (rst_n),
      .d_async (pin_in),
      .q_sync  (in_sync)
  );

  // in_prev resets to the synchroniser's reset value, so leaving reset with a
  // pin already high is not mistaken for a rising edge.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      in_prev <= '0;
    end else begin
      in_prev <= in_sync;
    end
  end

  logic [WIDTH-1:0] rise;
  logic [WIDTH-1:0] fall;

  assign rise = in_sync & ~in_prev;
  assign fall = ~in_sync & in_prev;

  //---------------------------------------------------------------------------
  // Registers
  //---------------------------------------------------------------------------
  logic [WIDTH-1:0] status_clear;

  assign status_clear = (wr_en && addr == ADDR_STATUS) ? wr_data : '0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_q     <= '0;
      dir_q     <= '0;
      rise_en_q <= '0;
      fall_en_q <= '0;
    end else if (wr_en) begin
      unique case (addr)
        ADDR_OUT:     out_q     <= wr_data;
        ADDR_DIR:     dir_q     <= wr_data;
        ADDR_OUT_SET: out_q     <= out_q | wr_data;
        ADDR_OUT_CLR: out_q     <= out_q & ~wr_data;
        ADDR_RISE_EN: rise_en_q <= wr_data;
        ADDR_FALL_EN: fall_en_q <= wr_data;
        default:      ;  // IN is read only; STATUS is handled below
      endcase
    end
  end

  // Set beats clear: an event in the clearing cycle is kept.
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      status_q <= '0;
    end else begin
      status_q <= (status_q & ~status_clear)
                | (rise & rise_en_q)
                | (fall & fall_en_q);
    end
  end

  //---------------------------------------------------------------------------
  // Read mux and outputs
  //---------------------------------------------------------------------------
  always_comb begin
    unique case (addr)
      ADDR_OUT:     rd_data = out_q;
      ADDR_DIR:     rd_data = dir_q;
      ADDR_IN:      rd_data = in_sync;
      ADDR_RISE_EN: rd_data = rise_en_q;
      ADDR_FALL_EN: rd_data = fall_en_q;
      ADDR_STATUS:  rd_data = status_q;
      default:      rd_data = '0;  // OUT_SET and OUT_CLR are write only
    endcase
  end

  assign pin_out = out_q;
  assign pin_oe  = dir_q;
  assign irq     = |status_q;

  //---------------------------------------------------------------------------
  // Elaboration-time checks
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (WIDTH < 1 || WIDTH > 32) begin
      $fatal(1, "gpio: WIDTH must be 1 to 32 (got %0d)", WIDTH);
    end
    if (SYNC_STAGES < 2) begin
      $fatal(1, "gpio: SYNC_STAGES must be >= 2 (got %0d)", SYNC_STAGES);
    end
  end
`endif

endmodule

`default_nettype wire
