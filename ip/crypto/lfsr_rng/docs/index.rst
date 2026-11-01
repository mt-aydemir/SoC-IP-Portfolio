.. _ip-lfsr_rng:

========
lfsr_rng
========

Maximal-length linear-feedback shift register as a pseudo-random bit source:
``STEPS`` fresh bits per draw, one draw per cycle, a run-time seed and a
stream output.

.. warning::

   An LFSR is not a cryptographic generator. It is linear, so ``2*WIDTH``
   consecutive output bits determine the whole sequence - the
   Berlekamp-Massey algorithm recovers it, and the regression does exactly
   that. Use it for test patterns, scramblers, dither, BIST and randomised
   arbitration, never for keys, nonces or masks.

Functional description
======================

The sequence
------------

Fibonacci form over the bits ``b[t]`` of the sequence:

.. code-block:: text

   b[t] = XOR over k in TAPS(WIDTH) of b[t-k]

The state holds the last ``WIDTH`` bits, ``b[t-1]`` in bit 0, and a step
shifts the new bit in at bit 0. ``TAPS(WIDTH)`` comes from a table of one
primitive feedback polynomial per width (Xilinx XAPP052), so the state
visits every one of the ``2**WIDTH - 1`` non-zero values before it repeats.
The all-zero state maps to itself and is never entered: a zero seed is
replaced by 1.

Draws
-----

A draw advances the register ``STEPS`` times in one cycle - the composition
of ``STEPS`` steps is still a network of XORs, ``STEPS`` levels deep - and
``m_data`` is the low ``STEPS`` bits of the new state: the bits just
generated, the newest in bit 0. Consecutive draws are consecutive,
non-overlapping ``STEPS``-bit pieces of the sequence. When ``STEPS`` divides
``2**WIDTH - 1`` the draws repeat after ``(2**WIDTH - 1) / STEPS`` of them,
and in general after ``(2**WIDTH - 1) / gcd(2**WIDTH - 1, STEPS)``.

Seeding
-------

``seed_load`` replaces the state with ``seed`` and generates the first draw
from it on the same edge; ``m_data`` on the next cycle is that draw. It wins
over ``m_ready``: a draw consumed on the same edge is the last of the old
sequence. After reset the state is ``SEED`` advanced by one draw, and
``m_valid`` rises on the first edge after the reset is released.

Block diagram
=============

.. code-block:: text

   seed --+                       +--------------------+
          | (zero -> 1)           |  STEPS x  step:    |
          +--> mux --> source --> |  shift in          | --> state --> m_data
   state -----^  ^                |  XOR(state & TAPS) |       |
                 seed_load        +--------------------+       |
                                                               +--> back to mux

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
   * - ``WIDTH``
     - ``int unsigned``
     - 32
     - 2 to 64
     - State width; the period is ``2**WIDTH - 1``.
   * - ``STEPS``
     - ``int unsigned``
     - 8
     - 1 to ``WIDTH``
     - Bits per draw.
   * - ``SEED``
     - ``logic [63:0]``
     - 1
     - any
     - Reset state; its low ``WIDTH`` bits are used, zero means 1.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 22 8 18 52

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``, ``rst_n``
     - in
     - 1
     - Clock and active-low asynchronous reset.
   * - ``seed_load``
     - in
     - 1
     - Restart the sequence from ``seed``.
   * - ``seed``
     - in
     - ``WIDTH``
     - The new state; zero is replaced by 1.
   * - ``m_valid`` / ``m_ready``
     - out / in
     - 1
     - Draw handshake; a draw is consumed on every edge with ``m_ready``
       high.
   * - ``m_data``
     - out
     - ``STEPS``
     - The draw, newest bit in bit 0.

Integration notes
-----------------

* For a scrambler, use ``STEPS`` equal to the data width and XOR ``m_data``
  into the stream; the descrambler is a second instance with the same seed.
* Two instances with different widths, or the same width and different
  seeds, are still correlated in the ways linear sequences are; do not rely
  on their independence for statistics.
* The critical path is ``STEPS`` levels of XOR; for large ``STEPS`` the
  timing is set by the widest feedback polynomial in the table, at most six
  taps.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_lfsr_rng.py``
     - Draw for draw against a model of the recurrence: the reset state and
       first draw, one draw per cycle, a draw held under a stall, seed
       loads including the zero seed, a seed load on the same edge as a
       consumed draw, a reset mid-sequence, and long random runs with
       back-pressure and reseeding. A property test runs Berlekamp-Massey
       on the design's own output and checks that the recovered polynomial
       has degree ``WIDTH`` and is primitive, by factoring
       ``2**WIDTH - 1`` - which is what makes the model's copy of the tap
       table trustworthy. Run at ``WIDTH`` = 2, 17, 32, 59, 62 and 64.
   * - ``tb/tb_lfsr_rng.sv``
     - Exhaustive periods: fifteen instances, ``WIDTH`` = 2 to 16, each run
       until its state first returns, which must take exactly
       ``2**WIDTH - 1`` steps; two more check the draw period with
       ``STEPS`` > 1. A ``WIDTH`` = 20, ``STEPS`` = 5 instance is compared
       draw for draw with a bit-serial model under back-pressure and random
       reseeding.
   * - ``formal/lfsr_rng_formal.sv``
     - k-induction proof at ``WIDTH=8 STEPS=3``: equivalence with a
       bit-serial model of the recurrence, seeding and stalls included; the
       state never reaches zero.

.. code-block:: bash

   ctest --test-dir build -R 'lfsr_rng'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration. The
critical path is the seed multiplexer followed by ``STEPS`` levels of the
feedback XOR into the state register.
