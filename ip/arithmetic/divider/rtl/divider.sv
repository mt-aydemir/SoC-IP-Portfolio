//=============================================================================
// Module      : divider
// Category    : arithmetic
// Description : Sequential restoring divider producing quotient and remainder,
//               signed or unsigned, with ready/valid interfaces.
//
// Division is the one basic arithmetic operation with no cheap combinational
// form. A single-cycle divider is an enormous amount of logic and sets the
// clock period for the whole design, so this block is sequential: it consumes
// one bit of quotient per cycle and takes WIDTH cycles per division. That is
// the trade every practical divider makes.
//
// ALGORITHM
//   Restoring shift-subtract, the long division taught in school written in
//   binary. Each iteration shifts the working remainder and the quotient left
//   by one, then tries to subtract the divisor:
//
//     {remainder, quotient} <<= 1
//     if (remainder >= divisor) { remainder -= divisor; quotient[0] = 1; }
//
//   "Restoring" refers to how the trial subtraction is handled: the value is
//   only committed when it does not go negative, so nothing has to be undone.
//   The comparison and the subtraction share one adder in hardware.
//
//   The working remainder is one bit wider than the operands. That extra bit
//   is not optional: after the shift, the value being compared against the
//   divisor can legitimately need WIDTH+1 bits, and truncating it produces a
//   quotient that is wrong only for some inputs, which is the worst kind of
//   wrong.
//
// SIGNED DIVISION
//   Signed division is performed on magnitudes and the signs are applied
//   afterwards, because the shift-subtract recurrence is only valid for
//   non-negative values.
//
//   The result follows the truncated convention that C and SystemVerilog both
//   use: the quotient is rounded towards zero, and the remainder takes the
//   sign of the *dividend*. So -7 / 2 is -3 remainder -1, not -4 remainder 1.
//   The identity dividend == quotient*divisor + remainder holds either way;
//   only the rounding direction differs.
//
//   One case has no correct answer: the most negative value divided by -1
//   overflows, because its magnitude is not representable. It is reported
//   through overflow rather than being allowed to wrap silently.
//
// DIVISION BY ZERO
//   Flagged on div_by_zero and completed in one cycle rather than stalling.
//   The results follow the convention of returning all-ones for the quotient
//   and the dividend for the remainder, which is what most processors do.
//
// Parameters
//   WIDTH   Operand width in bits.
//   SIGNED  Interpret operands as two's complement. 0/1.
//
// Latency     : WIDTH + 2 cycles per division
// Throughput  : one division per WIDTH + 2 cycles; not pipelined
// Reset       : asynchronous assertion, synchronous release, active low
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module divider #(
    parameter int unsigned WIDTH  = 32,
    parameter int unsigned SIGNED = 0
) (
    input  wire                    clk,
    input  wire                    rst_n,

    input  wire                    s_valid,
    output logic                   s_ready,
    input  wire  [WIDTH-1:0]       dividend,
    input  wire  [WIDTH-1:0]       divisor,

    output logic                   m_valid,
    input  wire                    m_ready,
    output logic [WIDTH-1:0]       quotient,
    output logic [WIDTH-1:0]       remainder,
    output logic                   div_by_zero,
    output logic                   overflow
);

  localparam bit          IS_SIGNED  = (SIGNED != 0);
  localparam int unsigned CNT_WIDTH  = $clog2(WIDTH + 1);

  typedef enum logic [1:0] {
    S_IDLE,
    S_ITERATE,
    S_PRESENT
  } state_e;

  state_e                 state_q;
  logic [CNT_WIDTH-1:0]   count_q;

  // The guard bit lives in the trial subtraction below, not in this register.
  // After every iteration the stored remainder is strictly less than the
  // divisor - that is the invariant the algorithm maintains - so it always
  // fits in WIDTH bits. Carrying a WIDTH+1st bit here would be a flip-flop
  // that is provably always zero.
  logic [WIDTH-1:0]       rem_q;
  logic [WIDTH-1:0]       quot_q;
  logic [WIDTH-1:0]       divisor_q;

  logic                   quot_negative_q;
  logic                   rem_negative_q;
  logic                   div_by_zero_q;
  logic                   overflow_q;

  //---------------------------------------------------------------------------
  // Operand preparation
  //---------------------------------------------------------------------------
  logic             dividend_negative;
  logic             divisor_negative;
  logic [WIDTH-1:0] dividend_magnitude;
  logic [WIDTH-1:0] divisor_magnitude;
  logic             zero_divisor;
  logic             signed_overflow;

  assign dividend_negative = IS_SIGNED && dividend[WIDTH-1];
  assign divisor_negative  = IS_SIGNED && divisor[WIDTH-1];

  assign dividend_magnitude = dividend_negative ? (~dividend + WIDTH'(1)) : dividend;
  assign divisor_magnitude  = divisor_negative  ? (~divisor  + WIDTH'(1)) : divisor;

  assign zero_divisor = (divisor == '0);

  // The one signed case with no representable answer: most-negative / -1.
  assign signed_overflow = IS_SIGNED &&
                           (dividend == {1'b1, {(WIDTH-1){1'b0}}}) &&
                           (&divisor);

  //---------------------------------------------------------------------------
  // One restoring iteration.
  //
  // The shifted remainder takes its new low bit from the top of the quotient
  // register, which is where the dividend is progressively consumed from.
  //---------------------------------------------------------------------------
  logic [WIDTH:0] shifted_rem;
  logic [WIDTH:0] trial;
  logic           trial_fits;

  // WIDTH+1 bits wide: the shift can push the remainder above the operand
  // range, and comparing a truncated value against the divisor would give the
  // wrong quotient bit for some inputs.
  assign shifted_rem = {rem_q, quot_q[WIDTH-1]};
  assign trial       = shifted_rem - {1'b0, divisor_q};

  // The subtraction's top bit *is* the comparison, so the two share one adder
  // rather than costing an adder plus a comparator.
  //
  // That holds because of the algorithm's invariant, rem_q < divisor_q. It
  // bounds shifted_rem below 2*divisor_q, so a successful trial leaves a value
  // below divisor_q with bit WIDTH clear, and an unsuccessful one goes
  // negative and sets it. Without the invariant the top bit would not be a
  // borrow and this shortcut would be wrong.
  assign trial_fits  = ~trial[WIDTH];

  //---------------------------------------------------------------------------
  // Control and datapath
  //---------------------------------------------------------------------------
  assign s_ready = (state_q == S_IDLE);
  assign m_valid = (state_q == S_PRESENT);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q         <= S_IDLE;
      count_q         <= '0;
      rem_q           <= '0;
      quot_q          <= '0;
      divisor_q       <= '0;
      quot_negative_q <= 1'b0;
      rem_negative_q  <= 1'b0;
      div_by_zero_q   <= 1'b0;
      overflow_q      <= 1'b0;
    end else begin
      unique case (state_q)
        S_IDLE: begin
          if (s_valid) begin
            rem_q           <= '0;
            quot_q          <= dividend_magnitude;
            divisor_q       <= divisor_magnitude;
            count_q         <= '0;
            div_by_zero_q   <= zero_divisor;
            overflow_q      <= signed_overflow;
            // The remainder takes the sign of the dividend; the quotient is
            // negative exactly when the operand signs differ.
            quot_negative_q <= dividend_negative ^ divisor_negative;
            rem_negative_q  <= dividend_negative;

            // A zero divisor or an overflowing signed case has a defined
            // answer that needs no iteration.
            state_q <= (zero_divisor || signed_overflow) ? S_PRESENT : S_ITERATE;
          end
        end

        S_ITERATE: begin
          // Both stored values are provably below the divisor, so the top bit
          // dropped here is always zero.
          if (trial_fits) begin
            rem_q  <= trial[WIDTH-1:0];
            quot_q <= {quot_q[WIDTH-2:0], 1'b1};
          end else begin
            rem_q  <= shifted_rem[WIDTH-1:0];
            quot_q <= {quot_q[WIDTH-2:0], 1'b0};
          end

          count_q <= count_q + CNT_WIDTH'(1);
          if (count_q == CNT_WIDTH'(WIDTH - 1)) begin
            state_q <= S_PRESENT;
          end
        end

        S_PRESENT: begin
          if (m_ready) begin
            state_q <= S_IDLE;
          end
        end

        default: begin
          state_q <= S_IDLE;
        end
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // Result formatting
  //---------------------------------------------------------------------------
  logic [WIDTH-1:0] quot_magnitude;
  logic [WIDTH-1:0] rem_magnitude;

  assign quot_magnitude = quot_q;
  assign rem_magnitude  = rem_q;

  always_comb begin
    div_by_zero = div_by_zero_q;
    overflow    = overflow_q;

    if (div_by_zero_q) begin
      // The convention most processors use: an all-ones quotient, and the
      // dividend returned untouched as the remainder. quot_q still holds the
      // dividend magnitude because a zero divisor skips the iteration phase,
      // so re-applying its sign reconstructs the original operand.
      quotient  = {WIDTH{1'b1}};
      remainder = rem_negative_q ? (~quot_q + WIDTH'(1)) : quot_q;
    end else if (overflow_q) begin
      // most-negative / -1: the true quotient is not representable, so the
      // wrapped value is returned and overflow says not to trust it.
      quotient  = {1'b1, {(WIDTH-1){1'b0}}};
      remainder = '0;
    end else begin
      quotient  = quot_negative_q ? (~quot_magnitude + WIDTH'(1)) : quot_magnitude;
      remainder = rem_negative_q  ? (~rem_magnitude  + WIDTH'(1)) : rem_magnitude;
    end
  end

  //---------------------------------------------------------------------------
  // Elaboration-time checks and assertions
  //---------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin : parameter_checks
    if (WIDTH < 2) begin
      $fatal(1, "divider: WIDTH must be >= 2 (got %0d)", WIDTH);
    end
  end

  property p_operands_stable;
    @(posedge clk) disable iff (!rst_n)
      (s_valid && !s_ready) |=> ($stable(dividend) && $stable(divisor));
  endproperty
  a_operands_stable : assert property (p_operands_stable)
    else $error("divider: operands changed while the request was stalled");

  property p_result_held;
    @(posedge clk) disable iff (!rst_n) (m_valid && !m_ready) |=> m_valid;
  endproperty
  a_result_held : assert property (p_result_held)
    else $error("divider: m_valid was withdrawn before m_ready");
`endif

endmodule

`default_nettype wire
