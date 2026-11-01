.. _ip-cic:

===
cic
===

Cascaded integrator-comb (Hogenauer) decimator with a run-time decimation rate
and a full-precision output.

Functional description
======================

Why a CIC
---------

A CIC decimator is ``STAGES`` cascaded moving sums of length ``R * M``
followed by keeping every ``R``-th sample, built so that it needs no
multiplier and no coefficient memory. That makes it the cheapest way to take
a high sample rate down by a large factor, and the first stage of almost
every digital down-converter. Its passband droops like a sinc to the power
``STAGES``; a short FIR after it, at the low rate, corrects that.

Structure
---------

.. code-block:: text

   integrators   i[0] <= i[0] + x
                 i[s] <= i[s] + i[s-1]      (the previous stage's register)
   decimation    every rate-th accepted sample passes i[STAGES-1] on
   combs         c[s] = c[s-1] - (c[s-1], DIFF_DELAY outputs ago)

Each integrator adds the previous stage's *register*, so the chain is
pipelined: one adder per path, and ``STAGES - 1`` samples of pure delay that
do not change the response. The combs run once per output, computed in one
cycle into the output register.

Precision and wrap-around
-------------------------

The gain is ``(rate * DIFF_DELAY) ** STAGES``. Hogenauer showed that
``DATA_WIDTH + STAGES * log2(MAX_RATE * DIFF_DELAY)`` bits hold every output
exactly. The integrators themselves grow without bound on any input with a
DC component - but every register is that width and wraps, and
two's-complement arithmetic is exact modulo ``2 ** OUT_WIDTH``, so the combs'
differences undo every wrap. Nothing in the block may saturate: saturation
would break exactly that argument.

Rate
----

``rate`` is sampled with every input sample and must be 1 to ``MAX_RATE``;
an assertion checks it. A new value takes effect at the next decimation
point. The outputs straddling a change mix two rates, so change it between
bursts.

Flow control
------------

Only a sample that would produce an output while the output register is
still full is refused: ``s_ready = !(due && m_valid && !m_ready)``. All
other samples are accepted at one per cycle.

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
   * - ``STAGES``
     - ``int unsigned``
     - 4
     - 1 to 8
     - Integrator/comb pairs.
   * - ``MAX_RATE``
     - ``int unsigned``
     - 64
     - 2 to 65536
     - Largest decimation rate; sets the output width.
   * - ``DIFF_DELAY``
     - ``int unsigned``
     - 1
     - 1, 2
     - Comb differential delay.
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 16
     - 2 to 32
     - Signed input width.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 22 8 26 44

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``, ``rst_n``
     - in
     - 1
     - Clock and active-low asynchronous reset.
   * - ``rate``
     - in
     - ``$clog2(MAX_RATE+1)``
     - Decimation rate.
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
     - ``DATA_WIDTH + STAGES * $clog2(MAX_RATE * DIFF_DELAY)``
     - Exact signed output.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_cic.py``
     - A model following the register semantics above, and an independent
       reference: the input filtered by ``STAGES`` moving sums computed
       with numpy, sampled at the decimation phase - no integrator or comb
       involved. Covers the DC gain at every rate from 1 to ``MAX_RATE``, the
       impulse response, a full-scale input that wraps the integrators many
       times, full input rate, the back-pressure rule, rate changes between
       bursts, a reset mid-stream, and random rates, gaps and back-pressure.
   * - ``tb/tb_cic.sv``
     - ``DIFF_DELAY=2``, its own model, 40 bursts at random rates, a
       full-scale DC burst whose settled output is checked against the gain
       formula, and a reset in the middle of a burst.

.. code-block:: bash

   ctest --test-dir build -R 'cic'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration. The
integrators are one adder each; the critical path is the comb chain,
``STAGES`` subtractors into the output register.
