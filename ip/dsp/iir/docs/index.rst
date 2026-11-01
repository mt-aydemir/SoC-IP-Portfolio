.. _ip-iir:

===
iir
===

Second-order IIR section (biquad), direct form I, one sample per cycle, with
run-time coefficients, rounding and saturation.

Functional description
======================

The section computes

.. code-block:: text

   y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]

Higher-order filters are built as cascades of these sections. Every IIR design
tool factors a filter into second-order sections, because a cascade of
biquads is far less sensitive to coefficient quantisation than a single
high-order section.

Why direct form I
-----------------

Direct form I keeps two input delays and two output delays, twice the state of
direct form II. In exchange it has a single rounding point and no internal
node that can overflow: the only value that leaves full precision is the
output. In fixed point that is the form that is safe.

Fixed point
-----------

Coefficients are ``COEF_WIDTH``-bit signed numbers with ``COEF_FRAC``
fractional bits. With the defaults they span [-2, 2), which holds every
stable ``a1``. The five products are summed exactly, then

.. code-block:: text

   y = saturate(round(sum / 2**COEF_FRAC))

with rounding half up - add half an LSB, shift arithmetically - and
saturation to ``DATA_WIDTH``. The state keeps the *saturated* y: a filter
that overflows clips rather than wrapping, which is what stops one overflow
from turning into a full-scale oscillation. ``m_saturated`` flags every
output that was clipped. With ``COEF_FRAC = 0`` there is no rounding stage.

Rounding noise
--------------

Each output's rounding adds at most half an LSB. That error enters at the
output and then circulates through the recursive part alone, ``1 / A(z)``, so
its worst case is half an LSB times the L1 norm of ``1 / A(z)``'s impulse
response. For a narrow low-pass, with poles close to z = 1, that norm is
large - which is the usual reason to give the coefficients and the state more
bits than the signal.

Coefficients and flow control
-----------------------------

``coef_wr_en`` writes ``coef_data`` at ``coef_addr``: 0 ``b0``, 1 ``b1``,
2 ``b2``, 3 ``a1``, 4 ``a2``; other addresses are ignored. A sample uses the
coefficients in force when it is accepted. They reset to zero.

``s_ready = !m_valid || m_ready``: one sample per cycle, every register held
under a stall. The feedback path, from ``y[n-1]`` through a multiplier and the
adder to ``y[n]``, is the critical path and cannot be pipelined without
changing the filter.

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 18 14 10 20 38

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 16
     - 2 to 32
     - Signed sample and state width.
   * - ``COEF_WIDTH``
     - ``int unsigned``
     - 18
     - 2 to 32
     - Signed coefficient width.
   * - ``COEF_FRAC``
     - ``int unsigned``
     - 16
     - 0 to ``COEF_WIDTH - 1``
     - Fractional bits of the coefficients.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 26 8 22 44

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``, ``rst_n``
     - in
     - 1
     - Clock and active-low asynchronous reset.
   * - ``coef_wr_en``, ``coef_addr``, ``coef_data``
     - in
     - 1, 3, ``COEF_WIDTH``
     - Coefficient write port.
   * - ``s_valid`` / ``s_ready``
     - in / out
     - 1
     - Input handshake.
   * - ``s_data``
     - in
     - ``DATA_WIDTH``
     - Signed input sample.
   * - ``m_valid`` / ``m_ready``
     - out / in
     - 1
     - Output handshake.
   * - ``m_data``, ``m_saturated``
     - out
     - ``DATA_WIDTH``, 1
     - Output sample and its clip flag.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_iir.py``
     - A bit-exact model written from the fixed-point rules above. Covers the
       reset state, pass-through and delays through ``b0``, ``b1`` and
       ``b2``, first-order feedback, rounding half up on both signs,
       saturation and its flag, full rate, a reset mid-stream, random
       coefficients under gaps and back-pressure, and an RBJ-cookbook
       low-pass whose DC gain and impulse response are checked against the
       same filter in floating point, within the rounding-noise bound.
   * - ``tb/tb_iir.sv``
     - Two instances on one stream, ``COEF_FRAC=14`` and ``COEF_FRAC=0``,
       each with its own model; coefficient sets that include unstable
       ones, so saturation is exercised thousands of times.

.. code-block:: bash

   ctest --test-dir build -R 'iir'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration. The
critical path is the feedback loop: a multiplier, the five-input sum, the
rounding and the saturation, back into ``y[n-1]``.
