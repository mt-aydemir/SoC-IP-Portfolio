.. _ip-cordic:

======
cordic
======

Iterative CORDIC in circular coordinates, supporting rotation mode (sine and
cosine) and vectoring mode (magnitude and arctangent).

Functional description
======================

The block takes a vector ``(x, y)`` and an angle ``z`` over a ready/valid
handshake, performs ``ITERATIONS`` micro-rotations, and presents the rotated
vector and the residual angle over a second handshake.

CORDIC computes trigonometric functions using only additions, subtractions and
shifts — no multiplier and no lookup table of function values. That is why it
survives: on a device with no spare DSP slices it is often the only way to get
a sine at all, and its cost is almost independent of which function is being
computed.

How it works
------------

Each iteration rotates the vector by the fixed angle ``atan(2^-i)``, choosing
the direction that drives one variable towards zero. Because the angle is
``atan(2^-i)``, the rotation matrix entries are 1 and ``2^-i``, so the
"multiply" is an arithmetic shift:

.. code-block:: text

   x' = x -/+ (y >>> i)
   y' = y +/- (x >>> i)
   z' = z -/+ atan(2^-i)

**Rotation mode** drives ``z`` towards zero, so the vector ends up rotated by
the requested angle. Starting from ``(1/K, 0)`` it produces ``(cos z, sin z)``.

**Vectoring mode** drives ``y`` towards zero, so the vector ends up on the x
axis. ``x`` then holds ``K`` times the magnitude and ``z`` has accumulated the
original angle, ``atan(y/x)``.

.. list-table::
   :header-rows: 1
   :widths: 16 20 64

   * - Mode
     - Driven to zero
     - Result
   * - rotation
     - ``z``
     - ``(K(x cos z − y sin z), K(x sin z + y cos z), ≈0)``
   * - vectoring
     - ``y``
     - ``(K·sqrt(x² + y²), ≈0, z + atan(y/x))``

The gain
--------

The micro-rotations are not unit length — each scales the vector by
``sqrt(1 + 2^-2i)`` — so the result is multiplied by a constant
``K ≈ 1.6467602581210654``.

The block does not divide it out, because the correction depends on what the
caller wants. A sine generator folds ``1/K`` into its starting amplitude and
pays nothing; a magnitude computation needs a real multiply. Building the
multiply in would charge every caller for what only some need.

For callers that do need it, ``1/K = 0.6072529350088813``, which is
``32'd1304065748`` at 31 fractional bits. Pre-scaling the input by ``1/K``
rather than scaling the output is usually cheaper: one multiply instead of two
when both ``x`` and ``y`` matter.

Convergence range
-----------------

**Rotation** converges for ``|z| <= ~1.7433`` radians — the sum of all the
micro-rotation angles, a little beyond π/2. Angles outside that must be folded
into the first or fourth quadrant before being presented, and the sign of the
result corrected afterwards. The block raises ``out_of_range`` for such an
angle rather than returning a quietly wrong answer.

**Vectoring** converges for vectors in the right half plane, ``x > 0``. This
is *not* flagged, because the check would need the full-precision sign of
``x`` and is trivially done by the caller: negate the vector and add π to the
resulting angle when ``x < 0``.

Number formats
--------------

Data
   Signed Q(``WIDTH``\ −2): 1.0 is ``2^(WIDTH-2)``, range [−2, 2). The two
   integer bits are headroom for the gain.

Angle
   Signed, scaled by π: π is ``2^(WIDTH-1)``, so the angle covers [−π, π)
   across the full signed range and wraps naturally. This representation is
   what makes the arctangent table exact at every width: the canonical table
   is stored once at 31 fractional bits and shifted down at elaboration,
   rather than being regenerated per width.

Internally ``x`` and ``y`` carry two guard bits above ``WIDTH``: the
intermediate vector grows by the gain during the iteration, and truncating it
to ``WIDTH`` would clip a result that is in range once the gain is accounted
for.

Block diagram
=============

.. code-block:: text

                +----------------------------------------------------------+
   s_valid ---->|   S_IDLE --> S_ITERATE x ITERATIONS --> S_PRESENT        |
   s_ready <----|     ^                                      | m_ready     |
                |     +--------------------------------------+             |
                |                                                          |
   x_in ======>|  x_q [W+2] ---+--> (>>> i) --+                            |
   y_in ======>|  y_q [W+2] ---|--> (>>> i) --|-- add/sub ---> x_q, y_q    |
   z_in ======>|  z_q [W]   ---|--------------|-- add/sub ---> z_q         |
                |               |              |       ^                   |
                |   direction = mode ? (y < 0) : (z >= 0)                  |
                |                              |       |                   |
                |          atan(2^-i) table ---+-------+                   |
                |          (canonical 31-bit, shifted at elaboration)      |
                |                                                          |
   x_out, y_out <==  x_q[W-1:0], y_q[W-1:0]                               |
   z_out       <==  z_q                                                    |
   out_of_range <-- |z_in| > limit, rotation mode only                     |
                +----------------------------------------------------------+

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 18 14 10 16 42

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``WIDTH``
     - ``int unsigned``
     - 16
     - 8 to 32
     - Data and angle width. Bounded above by the 31-bit canonical table.
   * - ``ITERATIONS``
     - ``int unsigned``
     - 16
     - 2 to 32
     - Micro-rotations per operation. Accuracy is about one bit per
       iteration, so there is nothing to gain beyond ``WIDTH``; a note is
       printed at elaboration if it is exceeded.

Illegal parameter values are rejected at elaboration with ``$fatal``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 18 10 12 60

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``
     - in
     - 1
     - Rising-edge clock.
   * - ``rst_n``
     - in
     - 1
     - Active-low reset. Asserted asynchronously, released synchronously.
   * - ``s_valid``
     - in
     - 1
     - The operands are valid.
   * - ``s_ready``
     - out
     - 1
     - The block is idle and accepts operands this cycle.
   * - ``mode_vectoring``
     - in
     - 1
     - 0 selects rotation, 1 selects vectoring. Sampled with the operands.
   * - ``x_in``, ``y_in``
     - in
     - ``WIDTH``
     - Input vector, signed Q(``WIDTH``\ −2).
   * - ``z_in``
     - in
     - ``WIDTH``
     - Input angle, signed, π = ``2^(WIDTH-1)``.
   * - ``m_valid``
     - out
     - 1
     - The result is valid. Held until ``m_ready``.
   * - ``m_ready``
     - in
     - 1
     - The sink accepts the result this cycle.
   * - ``x_out``, ``y_out``
     - out
     - ``WIDTH``
     - Output vector, scaled by ``K``.
   * - ``z_out``
     - out
     - ``WIDTH``
     - Residual angle (rotation) or accumulated angle (vectoring).
   * - ``out_of_range``
     - out
     - 1
     - The rotation angle was outside the convergence range. Always 0 in
       vectoring mode.

Usage examples
==============

A sine/cosine generator
-----------------------

Start from ``(1/K, 0)`` so the gain lands the result at unit amplitude.

.. code-block:: systemverilog

   cordic #(
     .WIDTH      (16),
     .ITERATIONS (16)
   ) u_nco (
     .clk            (clk),
     .rst_n          (rst_n),
     .s_valid        (phase_valid),
     .s_ready        (nco_ready),
     .mode_vectoring (1'b0),
     .x_in           (16'sd9949),    // round(2**14 / K)
     .y_in           (16'sd0),
     .z_in           (folded_phase),
     .m_valid        (iq_valid),
     .m_ready        (1'b1),
     .x_out          (cos_out),
     .y_out          (sin_out),
     .z_out          (),
     .out_of_range   (phase_error)
   );

Magnitude and phase of an I/Q sample
------------------------------------

.. code-block:: systemverilog

   cordic #(.WIDTH (16), .ITERATIONS (16)) u_polar (
     .clk (clk), .rst_n (rst_n),
     .s_valid (iq_valid), .s_ready (polar_ready),
     .mode_vectoring (1'b1),
     .x_in (i_sample), .y_in (q_sample), .z_in ('0),
     .m_valid (polar_valid), .m_ready (1'b1),
     .x_out (magnitude_times_k), .y_out (), .z_out (phase),
     .out_of_range ()
   );

Integration notes
-----------------

* Fold rotation angles into [−π/2, π/2] before presenting them, and correct
  the signs of ``x`` and ``y`` afterwards. ``out_of_range`` reports a failure
  to fold; it does not fold for you.
* For vectoring, keep ``x > 0``: negate both inputs and add π to ``z_out``
  when the input lies in the left half plane.
* The block is iterative, one operation per ``ITERATIONS + 2`` cycles. For a
  sample-rate NCO, unroll it into a pipeline of ``ITERATIONS`` stages instead
  — a different block, at roughly ``ITERATIONS`` times the area.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_cordic.py``
     - Sine and cosine at the cardinal angles, magnitude and arctangent of
       known vectors, the convergence-range flag, random angles across the
       convergence range and random vectors in vectoring mode against
       ``math.sin``, ``math.cos``, ``math.hypot`` and ``math.atan2``,
       accuracy scaling with ``ITERATIONS``, and back-to-back operations.
   * - ``tb/tb_cordic.sv``
     - Portable self-checking testbench against the simulator's real-valued
       ``$sin``, ``$cos``, ``$atan2`` and ``$sqrt``: the familiar angles,
       known vectors including the 3-4-5 triangle, the range flag, and 400
       random operations in each mode.

Accuracy is asserted as an absolute error bound in LSBs rather than as an
exact match. CORDIC is an approximation: each iteration adds roughly one bit,
and the fixed-point rounding at every step accumulates. A test demanding an
exact result would be testing a reference implementation's rounding, not the
design — while a wrong table entry or a mis-scaled angle still blows through
the bound by orders of magnitude.

.. code-block:: bash

   ctest --test-dir build -R 'cordic'

Timing
======

The block is timed by OpenSTA on its synthesised netlist at the clock period
in its ``add_ip()`` registration. The critical path is the variable arithmetic
shift — a ``$clog2(ITERATIONS)``-level mux tree, because the shift amount is
the iteration counter — followed by a ``WIDTH+2``-bit adder.
