.. _ip-fir:

===
fir
===

Transposed-form FIR filter, one sample per cycle, with run-time loadable
coefficients and a full-precision output.

Functional description
======================

Structure
---------

The filter computes ``y[n] = sum of h[k] * x[n-k]`` in transposed direct
form. Each accepted sample is multiplied by every coefficient at once, and the
products are added to partial sums held in a chain of registers:

.. code-block:: text

   y      <= x*h[0]      + z[1]
   z[k]   <= x*h[k]      + z[k+1]      k = 1 .. TAPS-2
   z[T-1] <= x*h[TAPS-1]

Unlike the direct form, which sums ``TAPS`` products in an adder tree, the
transposed form has one multiplier and one adder on its longest path however
many taps there are. That is why it is the usual structure for a full-rate
filter.

Precision
---------

A product of a ``DATA_WIDTH`` and a ``COEF_WIDTH`` signed number fits
``DATA_WIDTH + COEF_WIDTH`` bits, and a sum of ``TAPS`` of them fits
``$clog2(TAPS)`` more - including the corner where every sample and every
coefficient is the most negative value, which gives the largest positive
sum. The output is therefore exact and never saturates. Scaling it down is
the integrator's choice: take a slice of the bits, or pass it through
``requant_int8``.

Coefficients
------------

``coef_wr_en`` writes ``coef_data`` to ``h[coef_addr]`` on the edge;
addresses at or beyond ``TAPS`` are ignored. A product uses the coefficients
in force when its sample is accepted, so after a write the partial sums
already in the chain keep products formed with the old values, and the new
set is fully in effect ``TAPS`` samples later. Coefficients reset to zero.

Flow control
------------

``s_ready = !m_valid || m_ready``: the filter accepts a sample whenever its
output register is free or being emptied, runs at one sample per cycle under
no back-pressure, and holds every register under a stall.

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
   * - ``TAPS``
     - ``int unsigned``
     - 16
     - 2 to 256
     - Number of coefficients.
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 16
     - 2 to 32
     - Signed sample width.
   * - ``COEF_WIDTH``
     - ``int unsigned``
     - 16
     - 2 to 32
     - Signed coefficient width.

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
     - 1, ``$clog2(TAPS)``, ``COEF_WIDTH``
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
   * - ``m_data``
     - out
     - ``DATA_WIDTH + COEF_WIDTH + $clog2(TAPS)``
     - Exact signed output.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_fir.py``
     - A reference model written from the coefficient contract above. Covers
       the reset state, the impulse response with extreme coefficients, the
       DC gain, the precision corner, full rate, a coefficient change
       mid-stream, a reset mid-stream, 6000 samples under random gaps and
       back-pressure checked against both the model and ``numpy.convolve``,
       and a quantised windowed-sinc low-pass that must reject a high tone
       by more than 20 dB.
   * - ``tb/tb_fir.sv``
     - ``TAPS=7`` (not a power of two, so an out-of-range coefficient write
       is exercised), its own model, coefficient reloads including one in
       the middle of a stream.

.. code-block:: bash

   ctest --test-dir build -R 'fir'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration. The
critical path is one multiplier and one adder into a partial-sum register;
it does not grow with ``TAPS``.
