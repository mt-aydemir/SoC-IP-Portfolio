=================
SoC IP Portfolio
=================

A vendor-independent SystemVerilog IP library for FPGA and ASIC development.

Every block in this catalogue is written to the same standard: synthesisable
SystemVerilog-2017, fully parameterised, free of vendor primitives, and
verified by a flow that runs lint, simulation, synthesis and static timing
analysis in that order. An IP that fails any stage does not ship.

.. list-table::
   :header-rows: 0
   :widths: 30 70

   * - **Language**
     - SystemVerilog-2017, synthesisable subset
   * - **Targets**
     - FPGA and ASIC; no vendor primitives, no vendor attributes
   * - **Lint**
     - Verilator ``-Wall``, zero warnings tolerated
   * - **Simulation**
     - cocotb (Python) plus a self-checking SystemVerilog testbench per IP
   * - **Synthesis**
     - Yosys, mapped to a generic reference standard cell library
   * - **Timing**
     - OpenSTA on the mapped netlist
   * - **Build**
     - CMake + Ninja, strictly out of source
   * - **Licence**
     - Apache-2.0

Start here
==========

.. toctree::
   :maxdepth: 2
   :caption: Guides

   getting_started
   build_flow
   coding_style
   verification
   integration
   contributing

The catalogue
=============

.. toctree::
   :maxdepth: 2
   :caption: IP Catalogue

   ip/index

Indices
=======

* :ref:`genindex`
* :ref:`search`
