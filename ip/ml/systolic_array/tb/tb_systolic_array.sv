//=============================================================================
// Testbench   : tb_systolic_array
// Description : Self-checking SystemVerilog testbench for systolic_array.
//
// Checks the contract the array advertises: with a weight tile loaded, a
// vector presented on any cycle produces the matrix product of that vector
// exactly ROWS + COLS - 1 cycles later, and idle cycles contribute nothing.
//
// An identity tile is used before the randomised traffic because a skew or
// deskew off by one still produces plausible numbers - every result is a real
// sum of real products - and the identity case makes the misalignment visible
// directly rather than only through the reference model.
//
// Pass criterion: zero errors reported and "TEST PASSED" printed.
//
// Copyright (c) 2026 SoC IP Portfolio Contributors
// SPDX-License-Identifier: Apache-2.0
//=============================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_systolic_array;

  localparam int unsigned ROWS       = 8;
  localparam int unsigned COLS       = 8;
  localparam int unsigned DATA_WIDTH = 8;
  localparam int unsigned ACC_WIDTH  = 32;
  localparam int unsigned LATENCY    = ROWS + COLS - 1;
  localparam time         CLK_PERIOD = 4ns;
  localparam int unsigned NUM_TILES  = 20;
  localparam int unsigned NUM_VECS   = 40;

  localparam int signed DATA_MIN = -(2 ** (DATA_WIDTH - 1));
  localparam int signed DATA_MAX = (2 ** (DATA_WIDTH - 1)) - 1;

  logic                        clk;
  logic                        rst_n;
  logic                        w_valid;
  logic [COLS*DATA_WIDTH-1:0]  w_row;
  logic                        w_commit;
  logic                        a_valid;
  logic [ROWS*DATA_WIDTH-1:0]  a_vector;
  logic                        res_valid;
  logic [COLS*ACC_WIDTH-1:0]   res_vector;
  logic                        busy;

  int unsigned error_count;
  int unsigned check_count;

  // The tile currently published, mirrored by the testbench.
  logic signed [DATA_WIDTH-1:0] tile [ROWS][COLS];

  logic [COLS*ACC_WIDTH-1:0] expected [$];

  systolic_array #(
      .ROWS       (ROWS),
      .COLS       (COLS),
      .DATA_WIDTH (DATA_WIDTH),
      .ACC_WIDTH  (ACC_WIDTH)
  ) dut (
      .clk        (clk),
      .rst_n      (rst_n),
      .w_valid    (w_valid),
      .w_row      (w_row),
      .w_commit   (w_commit),
      .a_valid    (a_valid),
      .a_vector   (a_vector),
      .res_valid  (res_valid),
      .res_vector (res_vector),
      .busy       (busy)
  );

  initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD / 2) clk = ~clk;
  end

  //---------------------------------------------------------------------------
  // Reference model: res[m] = sum over k of tile[k][m] * a[k]
  //---------------------------------------------------------------------------
  function automatic logic [COLS*ACC_WIDTH-1:0] model(
      input logic [ROWS*DATA_WIDTH-1:0] vector);
    logic [COLS*ACC_WIDTH-1:0]    packed_result;
    logic signed [ACC_WIDTH-1:0]  sum;
    logic signed [DATA_WIDTH-1:0] activation;

    packed_result = '0;
    for (int unsigned m = 0; m < COLS; m++) begin
      sum = '0;
      for (int unsigned k = 0; k < ROWS; k++) begin
        activation = vector[k*DATA_WIDTH +: DATA_WIDTH];
        sum        = sum + ACC_WIDTH'(tile[k][m] * activation);
      end
      packed_result[m*ACC_WIDTH +: ACC_WIDTH] = sum;
    end
    return packed_result;
  endfunction

  //---------------------------------------------------------------------------
  // Push a tile in, row 0 first, and publish it. The array must be drained
  // before the commit, which the caller guarantees by waiting for !busy.
  //---------------------------------------------------------------------------
  task automatic load_tile(input logic signed [DATA_WIDTH-1:0] values [ROWS][COLS]);
    logic [COLS*DATA_WIDTH-1:0] row_word;

    wait (!busy);
    for (int unsigned k = 0; k < ROWS; k++) begin
      row_word = '0;
      for (int unsigned m = 0; m < COLS; m++) begin
        row_word[m*DATA_WIDTH +: DATA_WIDTH] = values[k][m];
      end
      @(negedge clk);
      w_valid = 1'b1;
      w_row   = row_word;
    end

    @(negedge clk);
    w_valid  = 1'b0;
    w_row    = '0;
    w_commit = 1'b1;
    @(negedge clk);
    w_commit = 1'b0;

    tile = values;
  endtask

  task automatic present(input logic [ROWS*DATA_WIDTH-1:0] vector);
    @(negedge clk);
    a_valid  = 1'b1;
    a_vector = vector;
    expected.push_back(model(vector));
  endtask

  task automatic idle_cycle();
    @(negedge clk);
    a_valid  = 1'b0;
    a_vector = '0;
  endtask

  //---------------------------------------------------------------------------
  // Monitor
  //---------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst_n && res_valid) begin
      if (expected.size() == 0) begin
        error_count++;
        $error("a result vector appeared with nothing outstanding at %0t",
               $time);
      end else begin
        automatic logic [COLS*ACC_WIDTH-1:0] want = expected.pop_front();
        check_count++;
        if (res_vector !== want) begin
          error_count++;
          for (int unsigned m = 0; m < COLS; m++) begin
            if (res_vector[m*ACC_WIDTH +: ACC_WIDTH] !==
                want[m*ACC_WIDTH +: ACC_WIDTH]) begin
              $error("vector %0d column %0d: expected %0d, got %0d at %0t",
                     check_count, m,
                     $signed(want[m*ACC_WIDTH +: ACC_WIDTH]),
                     $signed(res_vector[m*ACC_WIDTH +: ACC_WIDTH]), $time);
            end
          end
        end
      end
    end
  end

  initial begin
    logic signed [DATA_WIDTH-1:0] values [ROWS][COLS];
    logic [ROWS*DATA_WIDTH-1:0]   vector;
    int unsigned                  observed_latency;

    error_count = 0;
    check_count = 0;
    rst_n       = 1'b0;
    w_valid     = 1'b0;
    w_row       = '0;
    w_commit    = 1'b0;
    a_valid     = 1'b0;
    a_vector    = '0;
    for (int unsigned k = 0; k < ROWS; k++) begin
      for (int unsigned m = 0; m < COLS; m++) begin
        tile[k][m] = '0;
      end
    end

    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    @(posedge clk);
    #1;

    // --- reset state ---------------------------------------------------------
    if (res_valid !== 1'b0 || busy !== 1'b0) begin
      error_count++;
      $error("reset state wrong: res_valid=%0b busy=%0b", res_valid, busy);
    end

    // --- identity tile: column m must reproduce activation m -----------------
    for (int unsigned k = 0; k < ROWS; k++) begin
      for (int unsigned m = 0; m < COLS; m++) begin
        values[k][m] = (k == m) ? DATA_WIDTH'(1) : DATA_WIDTH'(0);
      end
    end
    load_tile(values);

    vector = '0;
    for (int unsigned k = 0; k < ROWS; k++) begin
      vector[k*DATA_WIDTH +: DATA_WIDTH] = DATA_WIDTH'(k + 1);
    end
    present(vector);
    idle_cycle();

    // --- measured latency ----------------------------------------------------
    observed_latency = 0;
    while (res_valid !== 1'b1 && observed_latency < LATENCY + 4) begin
      @(posedge clk);
      #1;
      observed_latency++;
    end
    if (observed_latency != LATENCY - 1) begin
      error_count++;
      $error("latency: expected %0d cycles, measured %0d",
             LATENCY, observed_latency + 1);
    end

    repeat (LATENCY + 4) @(posedge clk);

    // --- the extremes --------------------------------------------------------
    for (int unsigned k = 0; k < ROWS; k++) begin
      for (int unsigned m = 0; m < COLS; m++) begin
        values[k][m] = DATA_MIN;
      end
    end
    load_tile(values);

    vector = '0;
    for (int unsigned k = 0; k < ROWS; k++) begin
      vector[k*DATA_WIDTH +: DATA_WIDTH] = DATA_MIN;
    end
    present(vector);
    idle_cycle();
    repeat (LATENCY + 4) @(posedge clk);

    // --- randomised tiles and vectors, with gaps -----------------------------
    for (int unsigned t = 0; t < NUM_TILES; t++) begin
      for (int unsigned k = 0; k < ROWS; k++) begin
        for (int unsigned m = 0; m < COLS; m++) begin
          values[k][m] = DATA_WIDTH'($urandom());
        end
      end
      load_tile(values);

      for (int unsigned v = 0; v < NUM_VECS; v++) begin
        for (int unsigned k = 0; k < ROWS; k++) begin
          vector[k*DATA_WIDTH +: DATA_WIDTH] = DATA_WIDTH'($urandom());
        end
        present(vector);
        if ($urandom_range(0, 3) == 0) begin
          idle_cycle();
        end
      end
      idle_cycle();
      repeat (LATENCY + 4) @(posedge clk);
    end

    // --- verdict -------------------------------------------------------------
    if (expected.size() != 0) begin
      error_count++;
      $error("%0d vector(s) never produced a result", expected.size());
    end
    if (check_count == 0) begin
      error_count++;
      $error("no results were checked at all");
    end

    if (error_count == 0) begin
      $display("TEST PASSED: tb_systolic_array (%0dx%0d, %0d vectors)",
               ROWS, COLS, check_count);
      $finish;
    end else begin
      $display("TEST FAILED: tb_systolic_array, %0d error(s)", error_count);
      $fatal(1, "tb_systolic_array failed");
    end
  end

  initial begin
    #(CLK_PERIOD * 500000);
    $fatal(1, "tb_systolic_array: global timeout");
  end

endmodule

`default_nettype wire
