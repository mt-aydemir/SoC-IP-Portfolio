//=============================================================================
// Module      : reset_controller_formal
// Category    : clocking
// Description : Formal property wrapper for reset_controller.
//
// Proved with free-running clocks (FORMAL_MULTICLOCK), because the reset
// input is asynchronous: the clock, arst_n_in and sw_reset are free inputs
// that may change on any solver step. Configuration: three stages two
// cycles apart, a minimum assertion of three cycles, a two-stage input
// synchroniser. For every input sequence:
//
//   ASSERT    while arst_n_in is low every output is in reset and
//             reset_active is high - at once, with no clock edge
//   SEQUENCE  stage s is released exactly on the
//             (SYNC_STAGES + MIN_ASSERT_CYCLES + s * STAGE_DELAY + 1)-th
//             rising edge that finds arst_n_in high on the step before it -
//             so the stages leave reset in order, STAGE_DELAY apart, after
//             at least the minimum assertion - and stays released
//   SOFTWARE  a rising edge that samples sw_reset puts every stage back in
//             reset and the sequence restarts from the minimum assertion,
//             as after the synchroniser releases; before the synchroniser
//             releases, sw_reset has no effect
//   ACTIVE    reset_active is high exactly while the last stage is in reset
//
// The synchroniser chain and the sequence counter are probed and tied to
// the wrapper's count of edges.
//
// Covers: every stage released; a software reset after release and a
// second release; an asynchronous reset in the middle of the sequence.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module reset_controller_formal (
    input wire clk,
    input wire arst_n_in,
    input wire sw_reset
);

  localparam int unsigned N     = 3;
  localparam int unsigned DELAY = 2;
  localparam int unsigned MIN   = 3;
  localparam int unsigned SYNC  = 2;
  localparam int unsigned MAXC  = MIN + N * DELAY + 1;   // the RTL's MAX_COUNT
  localparam int unsigned KCAP  = SYNC + MAXC - 1;       // the count stops here

  (* gclk *) reg gclk;

  logic [N-1:0] rst_n_out;
  logic         reset_active;

  reset_controller #(
      .NUM_STAGES(N), .STAGE_DELAY(DELAY), .MIN_ASSERT_CYCLES(MIN), .SYNC_STAGES(SYNC)
  ) dut (
      .clk(clk), .arst_n_in(arst_n_in), .sw_reset(sw_reset),
      .rst_n_out(rst_n_out), .reset_active(reset_active));

  // formal-connect: f_sync = dut.u_sync.sync_q
  // formal-connect: f_count = dut.count_q
  (* keep *) wire [1:0] f_sync;
  (* keep *) wire [3:0] f_count;

  logic       p_clk = 1'b0, p_arst = 1'b0, p_sw = 1'b0;
  logic [N-1:0] p_out = '0;
  logic [3:0] k = '0;         // counted edges since release; SYNC means "counter just released"
  logic [3:0] k_now;
  logic       rise_edge;
  logic       released_all = 1'b0, sw_after = 1'b0, again = 1'b0, mid = 1'b0;

  assign rise_edge  = clk && !p_clk && p_arst && arst_n_in;
  assign k_now = !arst_n_in ? 4'd0
               : !rise_edge ? k
               : (p_sw && k >= 4'(SYNC)) ? 4'(SYNC)
               : (k == 4'(KCAP)) ? k : k + 4'd1;

  always @(posedge gclk) begin
    p_clk  <= clk;
    p_arst <= arst_n_in;
    p_sw   <= sw_reset;
    p_out  <= rst_n_out;
    k      <= k_now;
    if (rst_n_out[N-1]) released_all <= 1'b1;
    if (released_all && rise_edge && p_sw) sw_after <= 1'b1;
    if (sw_after && rst_n_out[N-1] && !p_out[N-1]) again <= 1'b1;
    if (!arst_n_in && p_arst && p_out[0] && !p_out[N-1]) mid <= 1'b1;
  end

  initial assume (!arst_n_in);

  always @(*) begin
    assert (k <= 4'(KCAP));
    if (!arst_n_in) assert (rst_n_out == '0 && reset_active);
    for (int s = 0; s < N; s++)
      assert (rst_n_out[s] == (k_now >= 4'(SYNC + MIN + s * DELAY + 1)));
    assert (reset_active == !rst_n_out[N-1]);
    // Probes: the synchroniser's thermometer code and the counter
    assert (f_sync == {k_now >= 4'd2, k_now >= 4'd1});
    assert (f_count == (k_now >= 4'(SYNC) ? k_now - 4'(SYNC) : 4'd0));
  end

  always @(*) begin
    cover (released_all);
    cover (again);
    cover (mid);
  end

endmodule

`default_nettype wire
