//=============================================================================
// Module      : i2c_master
// Category    : peripherals
// Description : I2C bus master driven by byte-level commands, with clock
//               stretching and multi-master arbitration.
//
// The host issues one command at a time on the s_ stream and receives one
// response per command on m_valid. A transaction is a sequence of commands:
//
//   START                      START or repeated START condition
//   WRITE  s_data              eight bits out, then the slave's acknowledge
//                              returned in m_nack (0 = ACK)
//   READ   s_nack              eight bits in, returned in m_data, then the
//                              master's acknowledge (s_nack = 1 for the last
//                              byte of a read)
//   STOP                       STOP condition, bus released
//
// Leaving the sequencing to the host keeps the block small and covers every
// device - register pointers, repeated starts, 10-bit addresses - without
// the block knowing about any of them.
//
// Bus
//   The lines are open drain. scl_oe / sda_oe high pull the line low; low
//   releases it to the pull-up. scl_i / sda_i are the line levels, which are
//   asynchronous (another master, a slave stretching the clock) and are
//   synchronised before use.
//
// Bit timing
//   Every bit is four phases of clk_div clk cycles. SCL is low in the first
//   and last and released in the middle two, so the SCL period is 4 * clk_div
//   clk cycles. Data changes only while SCL is low; START and STOP are the two
//   deliberate exceptions.
//
//   A phase in which SCL is released does not start counting until the line
//   is seen high. That is clock stretching: a slave holding SCL low simply
//   lengthens the phase. It also absorbs the bus rise time and the
//   synchroniser delay, so the SCL high time is never shorter than
//   2 * clk_div cycles.
//
//   clk_div has a floor. SDA is released for STOP two phases before it is
//   checked, so 2 * clk_div must cover the bus rise time plus SYNC_STAGES + 1
//   cycles of synchroniser delay; below that the master reports a STOP it
//   lost to nobody. Real rates are far above it (100 kHz from 100 MHz is
//   clk_div = 250).
//
// Arbitration
//   A master that releases SDA and reads it low has lost to another master
//   driving a 0. This is checked at the middle of the high time of every bit
//   the master sends as a 1, before a START, and two phases after the STOP
//   edge.
//   On loss the master releases both lines at once, abandons the command and
//   returns m_arb_lost; the host must wait for the bus to go idle before
//   trying again.
//
// Parameters
//   DIV_WIDTH    Width of clk_div. >= 2.
//   SYNC_STAGES  Line synchroniser depth. >= 2.
//
// Latency     : START and STOP take one bit time, WRITE and READ nine, all
//               plus any clock stretching
// Reset       : asynchronous assertion, synchronous release, active low.
//               Both lines released, idle.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module i2c_master #(
    parameter int unsigned DIV_WIDTH   = 16,
    parameter int unsigned SYNC_STAGES = 2
) (
    input  wire                 clk,
    input  wire                 rst_n,

    // Quarter SCL period in clk cycles; see the floor above. Change only
    // while idle.
    input  wire [DIV_WIDTH-1:0] clk_div,

    // Commands
    input  wire                 s_valid,
    output logic                s_ready,
    input  wire  [1:0]          s_cmd,
    input  wire  [7:0]          s_data,
    input  wire                 s_nack,

    // One response per command
    output logic                m_valid,
    output logic [7:0]          m_data,
    output logic                m_nack,
    output logic                m_arb_lost,

    output logic                busy,

    // Open-drain bus
    input  wire                 scl_i,
    input  wire                 sda_i,
    output logic                scl_oe,
    output logic                sda_oe
);

  localparam logic [1:0] CMD_START = 2'd0;
  localparam logic [1:0] CMD_STOP  = 2'd1;
  localparam logic [1:0] CMD_WRITE = 2'd2;
  localparam logic [1:0] CMD_READ  = 2'd3;

  //---------------------------------------------------------------------------
  // Line synchronisers. Reset to the idle (released) level.
  //---------------------------------------------------------------------------
  logic scl_s;
  logic sda_s;

  cdc_sync_2ff #(
      .WIDTH       (2),
      .STAGES      (SYNC_STAGES),
      .RESET_VALUE (2'b11)
  ) u_sync (
      .clk     (clk),
      .rst_n   (rst_n),
      .d_async ({scl_i, sda_i}),
      .q_sync  ({scl_s, sda_s})
  );

  //---------------------------------------------------------------------------
  // Bit-level operations
  //---------------------------------------------------------------------------
  localparam logic [1:0] OP_START = 2'd0;
  localparam logic [1:0] OP_STOP  = 2'd1;
  localparam logic [1:0] OP_WRITE = 2'd2;   // send one bit
  localparam logic [1:0] OP_READ  = 2'd3;   // release SDA and sample it

  logic       active;
  logic [1:0] cmd_q;
  logic       nack_q;
  logic [3:0] bit_index;          // 0..8 within a byte command
  logic [1:0] phase;
  logic [DIV_WIDTH-1:0] count;
  logic [7:0] tx_shift;
  logic [7:0] rx_shift;
  logic       ack_q;

  // The operation for a given bit of a command.
  function automatic logic [1:0] op_for(input logic [1:0] cmd,
                                        input logic [3:0] index);
    unique case (cmd)
      CMD_START: op_for = OP_START;
      CMD_STOP:  op_for = OP_STOP;
      CMD_WRITE: op_for = (index < 4'd8) ? OP_WRITE : OP_READ;
      default:   op_for = (index < 4'd8) ? OP_READ  : OP_WRITE;
    endcase
  endfunction

  // Line levels for each phase of each operation: {scl released, sda
  // released}. START's first phase leaves SCL where it is, low after a bit or
  // high on an idle bus; that case is handled where the table is used.
  function automatic logic [1:0] lines_for(input logic [1:0] op,
                                           input logic [1:0] ph,
                                           input logic wbit);
    unique case (op)
      OP_START: unique case (ph)
                  2'd0:    lines_for = 2'b01;   // SCL as is, release SDA
                  2'd1:    lines_for = 2'b11;   // SCL high
                  2'd2:    lines_for = 2'b10;   // SDA falls: START
                  default: lines_for = 2'b00;   // SCL falls
                endcase
      OP_STOP:  unique case (ph)
                  2'd0:    lines_for = 2'b00;
                  2'd1:    lines_for = 2'b10;   // SCL high, SDA low
                  default: lines_for = 2'b11;   // SDA rises: STOP
                endcase
      OP_WRITE: lines_for = {(ph == 2'd1) || (ph == 2'd2), wbit};
      default:  lines_for = {(ph == 2'd1) || (ph == 2'd2), 1'b1};
    endcase
  endfunction

  logic [1:0] op;
  logic       wbit;
  logic last_bit;
  logic scl_released;

  assign op       = op_for(cmd_q, bit_index);
  assign wbit     = (cmd_q == CMD_WRITE) ? tx_shift[7] : nack_q;
  assign last_bit = (cmd_q == CMD_START || cmd_q == CMD_STOP) || (bit_index == 4'd8);
  assign scl_released = !scl_oe;

  assign s_ready = !active;
  assign busy    = active;

  //---------------------------------------------------------------------------
  // Sequencer
  //---------------------------------------------------------------------------
  // The output enables for a phase, {scl_oe, sda_oe}. START's first phase
  // keeps SCL as it is, so the current enable is passed in.
  function automatic logic [1:0] oe_for(input logic [1:0] o,
                                        input logic [1:0] ph,
                                        input logic b, input logic scl_now);
    logic [1:0] l;
    l = lines_for(o, ph, b);
    oe_for = {(o == OP_START && ph == 2'd0) ? scl_now : !l[1], !l[0]};
  endfunction

  // The next bit of a byte command. tx_shift moves on only after a data bit
  // of a WRITE.
  logic [3:0] next_index;
  logic [7:0] next_tx;
  logic       next_wbit;

  assign next_index = bit_index + 4'd1;
  assign next_tx    = (cmd_q == CMD_WRITE) ? {tx_shift[6:0], 1'b0} : tx_shift;
  assign next_wbit  = (cmd_q == CMD_WRITE) ? next_tx[7] : nack_q;

  logic stretching;
  assign stretching = scl_released && !scl_s;

  // Arbitration is lost if SDA reads low where this master released it: the
  // middle of a bit sent as 1 (end of phase 1), the high SCL before a START
  // (end of phase 1), and after the STOP edge (end of phase 3, leaving two
  // phases for the released line to come back through the synchroniser).
  logic arb_lost_now;
  always_comb begin
    arb_lost_now = 1'b0;
    unique case (op)
      OP_START: arb_lost_now = (phase == 2'd1) && !sda_s;
      OP_STOP:  arb_lost_now = (phase == 2'd3) && !sda_s;
      OP_WRITE: arb_lost_now = (phase == 2'd1) && wbit && !sda_s;
      default:  arb_lost_now = 1'b0;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active     <= 1'b0;
      cmd_q      <= CMD_START;
      nack_q     <= 1'b0;
      bit_index  <= '0;
      phase      <= '0;
      count      <= '0;
      tx_shift   <= '0;
      rx_shift   <= '0;
      ack_q      <= 1'b0;
      m_valid    <= 1'b0;
      m_data     <= '0;
      m_nack     <= 1'b0;
      m_arb_lost <= 1'b0;
      scl_oe     <= 1'b0;
      sda_oe     <= 1'b0;
    end else begin
      m_valid <= 1'b0;

      if (!active) begin
        if (s_valid) begin
          active    <= 1'b1;
          cmd_q     <= s_cmd;
          nack_q    <= s_nack;
          tx_shift  <= s_data;
          rx_shift  <= '0;
          ack_q     <= 1'b0;
          bit_index <= '0;
          phase     <= '0;
          count     <= clk_div - DIV_WIDTH'(1);
          {scl_oe, sda_oe} <= oe_for(op_for(s_cmd, 4'd0), 2'd0,
                                     (s_cmd == CMD_WRITE) ? s_data[7] : s_nack,
                                     scl_oe);
        end
      end else if (stretching) begin
        // SCL released but held low: wait, without counting
      end else if (count != '0) begin
        count <= count - DIV_WIDTH'(1);
      end else if (arb_lost_now) begin
        scl_oe     <= 1'b0;
        sda_oe     <= 1'b0;
        active     <= 1'b0;
        m_valid    <= 1'b1;
        m_data     <= '0;
        m_nack     <= 1'b1;
        m_arb_lost <= 1'b1;
      end else begin
        count <= clk_div - DIV_WIDTH'(1);

        // Sample in the middle of the high time.
        if (phase == 2'd1 && op == OP_READ) begin
          if (bit_index < 4'd8) begin
            rx_shift <= {rx_shift[6:0], sda_s};
          end else begin
            ack_q <= sda_s;
          end
        end

        if (phase != 2'd3) begin
          phase <= phase + 2'd1;
          {scl_oe, sda_oe} <= oe_for(op, phase + 2'd1, wbit, scl_oe);
        end else if (last_bit) begin
          active     <= 1'b0;
          m_valid    <= 1'b1;
          m_data     <= (cmd_q == CMD_READ) ? rx_shift : 8'h00;
          m_nack     <= (cmd_q == CMD_WRITE) ? ack_q : 1'b0;
          m_arb_lost <= 1'b0;
        end else begin
          bit_index        <= next_index;
          tx_shift         <= next_tx;
          phase            <= 2'd0;
          {scl_oe, sda_oe} <= oe_for(op_for(cmd_q, next_index), 2'd0,
                                     next_wbit, scl_oe);
        end
      end
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (DIV_WIDTH < 2) begin
      $fatal(1, "i2c_master: DIV_WIDTH must be >= 2 (got %0d)", DIV_WIDTH);
    end
    if (SYNC_STAGES < 2) begin
      $fatal(1, "i2c_master: SYNC_STAGES must be >= 2 (got %0d)", SYNC_STAGES);
    end
  end

  // The floor: two phases must outlast the synchroniser.
  property p_div_floor;
    @(posedge clk) disable iff (!rst_n)
      (s_valid && s_ready) |-> (32'(clk_div) * 2 >= SYNC_STAGES + 1);
  endproperty
  a_div_floor : assert property (p_div_floor)
    else $error("i2c_master: clk_div %0d is below the floor for SYNC_STAGES=%0d",
                clk_div, SYNC_STAGES);
`endif

endmodule

`default_nettype wire
