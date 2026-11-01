//=============================================================================
// Module      : cdc_reset_sync_formal
// Category    : cdc
// Description : Formal property wrapper for cdc_reset_sync.
//
// Proved with free-running clocks (FORMAL_MULTICLOCK): the clock and the
// asynchronous reset input are free inputs that may change on any solver
// step, in any order. Two instances, two and three stages. For every input
// sequence:
//
//   ASSERT    while arst_n_in is low, rst_n_out is low - at once, with no
//             clock edge
//   RELEASE   rst_n_out rises only on a rising clock edge, and exactly on
//             the STAGES-th rising edge that finds arst_n_in already high on
//             the step before it - never earlier, and never later; a reset
//             pulse at any point starts the count again
//
// The synchroniser chain is probed and must hold the thermometer code that
// count implies.
//
// Covers: each instance releases, and a reset pulse arrives while a release
// is half-way through the chain.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none

module cdc_reset_sync_formal (
    input wire clk,
    input wire arst_n_in
);

  (* gclk *) reg gclk;

  logic out2, out3;

  cdc_reset_sync #(.STAGES(2)) dut2 (.clk(clk), .arst_n_in(arst_n_in), .rst_n_out(out2));
  cdc_reset_sync #(.STAGES(3)) dut3 (.clk(clk), .arst_n_in(arst_n_in), .rst_n_out(out3));

  // formal-connect: f_q2 = dut2.sync_q
  // formal-connect: f_q3 = dut3.sync_q
  (* keep *) wire [1:0] f_q2;
  (* keep *) wire [2:0] f_q3;

  logic       p_clk = 1'b0, p_arst = 1'b0, p_out2 = 1'b0, p_out3 = 1'b0;
  logic [1:0] edges = '0;   // counted rising edges since release, saturating at 3
  logic [1:0] now;          // the count including an edge on this step
  logic       rise, counted;

  assign rise    = clk && !p_clk;
  // An edge samples the previous step, so it counts only if the reset was
  // already released there.
  assign counted = rise && p_arst && arst_n_in;
  assign now     = !arst_n_in ? 2'd0 : (counted && edges != 2'd3) ? edges + 2'd1 : edges;

  always @(posedge gclk) begin
    p_clk  <= clk;
    p_arst <= arst_n_in;
    p_out2 <= out2;
    p_out3 <= out3;
    edges  <= now;
  end

  initial assume (!arst_n_in);

  always @(*) begin
    if (!arst_n_in) assert (!out2 && !out3);
    assert (out2 == (now >= 2'd2));
    assert (out3 == (now >= 2'd3));
    if (out2 && !p_out2) assert (rise);
    if (out3 && !p_out3) assert (rise);
    // Thermometer code in the chains: bit k is set once k+1 edges counted.
    assert (f_q2 == {now >= 2'd2, now >= 2'd1});
    assert (f_q3 == {now >= 2'd3, now >= 2'd2, now >= 2'd1});
  end

  always @(*) begin
    cover (out2 && !p_out2);
    cover (out3 && !p_out3);
    cover (!arst_n_in && p_arst && edges == 2'd2);
  end

endmodule

`default_nettype wire
