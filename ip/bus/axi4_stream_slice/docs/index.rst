.. _ip-axi4_stream_slice:

=================
axi4_stream_slice
=================

AMBA AXI4-Stream register slice that breaks the forward path, the backward
(``TREADY``) path, or both, without losing throughput.

Functional description
======================

Why a slice
-----------

A stream between two blocks that each close timing on their own can still
fail on the path between them, in one of two directions: ``TVALID`` and the
payload travelling forward, or ``TREADY`` travelling back. Inserting a slice
cuts one or both with registers. Nothing about the stream changes except its
timing - every beat arrives exactly once, in order, with every sideband - so
slices can be added wherever timing needs them.

Modes
-----

.. list-table::
   :header-rows: 1
   :widths: 8 12 80

   * - MODE
     - Name
     - Structure
   * - 0
     - BYPASS
     - Wires, so a slice can be configured away without editing the design
       around it.
   * - 1
     - FORWARD
     - One output register. ``TREADY`` passes back as
       ``!valid_q || m_axis_tready``: the register loads when it is empty or
       being emptied. Full throughput, one cycle of latency; the backward
       path is not cut.
   * - 2
     - REVERSE
     - ``TREADY`` is registered as ``!skid``. A beat arriving while the
       output stalls is caught in the skid register, because ``TREADY`` was
       already high from the cycle before; otherwise it passes straight
       through. Full throughput, no latency; the forward path is not cut.
   * - 3
     - FULL
     - A skid register in front of an output register. The output register
       loads whenever it is free - from the skid register if that holds a
       beat, otherwise from the input. Both paths cut at full throughput and
       one cycle of latency, with no combinational path from any input to
       any output.
   * - 4
     - LIGHT
     - One register and a full flag: ``TREADY`` is ``!full`` and ``TVALID``
       is ``full``. Both paths cut with half the storage of FULL, at most one
       beat every two cycles.

FULL needs two registers because ``TREADY`` is registered: in the cycle the
output stalls, the input has already been told it may send, so one beat has
to be absorbed somewhere other than the stalled output register. LIGHT avoids
the second register by never telling the input it may send while a beat is
held - hence its half rate.

Block diagram
=============

.. code-block:: text

   FULL (MODE 3)

   s_axis ---+---------------------+          +--------+
             |                     +--> mux ->| output |---> m_axis
             +--> [skid register] -+          +--------+
                        |                         |
   s_axis_tready <-- !skid              load = !valid || m_axis_tready

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
   * - ``MODE``
     - ``int unsigned``
     - 3
     - 0 to 4
     - Which paths are cut.
   * - ``DATA_WIDTH``
     - ``int unsigned``
     - 32
     - multiple of 8
     - ``TDATA`` width; ``TSTRB`` and ``TKEEP`` are ``DATA_WIDTH/8``.
   * - ``ID_WIDTH``
     - ``int unsigned``
     - 1
     - >= 1
     - ``TID`` width.
   * - ``DEST_WIDTH``
     - ``int unsigned``
     - 1
     - >= 1
     - ``TDEST`` width.
   * - ``USER_WIDTH``
     - ``int unsigned``
     - 1
     - >= 1
     - ``TUSER`` width.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 30 8 18 44

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``, ``rst_n``
     - in
     - 1
     - ``ACLK`` and ``ARESETn``.
   * - ``s_axis_tvalid`` / ``s_axis_tready``
     - in / out
     - 1
     - Input handshake.
   * - ``s_axis_tdata``, ``s_axis_tstrb``, ``s_axis_tkeep``, ``s_axis_tlast``
     - in
     - ``DATA_WIDTH``, ``DATA_WIDTH/8``, ``DATA_WIDTH/8``, 1
     - Input beat.
   * - ``s_axis_tid``, ``s_axis_tdest``, ``s_axis_tuser``
     - in
     - ``ID_WIDTH``, ``DEST_WIDTH``, ``USER_WIDTH``
     - Input sidebands.
   * - ``m_axis_tvalid`` / ``m_axis_tready``
     - out / in
     - 1
     - Output handshake.
   * - ``m_axis_t*``
     - out
     - as the input
     - Output beat and sidebands.

Integration notes
-----------------

* Choose the mode by the failing path: FORWARD when the payload is late at
  the sink, REVERSE when ``TREADY`` is late at the source, FULL when both
  or when the slice sits at a block boundary that must have registered
  outputs. LIGHT only for streams that never need full rate.
* Slices compose: two FORWARD slices pipeline the forward path twice. A FULL
  slice is not the same as FORWARD followed by REVERSE in latency, but both
  cut both paths.
* The slice adds no timing exception, and none may be added across it: a
  false or multicycle path over a slice undoes the slice.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_axi4_stream_slice.py``
     - Checks the reset state, first-beat latency, full-rate throughput,
       every sideband at its extremes, a stalled sink filling the slice to
       its mode's capacity and draining, a reset mid-stream, and 6000 beats
       under random gaps and back-pressure. A structural test changes
       ``TREADY`` and raises ``TVALID`` in the middle of cycles and checks
       that the paths the mode cuts do not respond before the edge. Run at
       the registered ``MODE=3`` and, by hand, at every other mode and at
       8-bit data.
   * - ``tb/tb_axi4_stream_slice.sv``
     - All five modes side by side, each with its own source and sink;
       payloads derived from the beat index. Random flow, then a full-rate
       phase that checks each mode's exact cycle count.
   * - ``formal/axi4_stream_slice_formal.sv``
     - k-induction proof of all five modes: beats leave once, in
       order, with every sideband; capacity, hold and each mode's ready
       timing.

.. code-block:: bash

   ctest --test-dir build -R 'axi4_stream_slice'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration.
``scripts/axi4_stream_slice.sdc`` declares no exception - the slice cuts
paths by construction - and reports the paths a mode leaves combinational
under named groups.
