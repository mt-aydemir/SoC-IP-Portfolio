==========
Build Flow
==========

The repository is driven by CMake with the Ninja generator. CMake is not
compiling C here: it is used as a dependency-aware job scheduler for the EDA
flow, and CTest is used as the regression runner.

The stages
==========

Every IP passes through the same pipeline. Each stage is a CTest fixture, so
the ordering is enforced by the test runner rather than by convention.

.. list-table::
   :header-rows: 1
   :widths: 10 18 20 52

   * - Stage
     - Tool
     - Driver
     - Pass criterion
   * - 1
     - Verilator ``--lint-only``
     - ``scripts/run_lint.py``
     - Zero errors **and** zero warnings under ``-Wall``
   * - 2
     - Verilator + cocotb
     - ``scripts/run_cocotb.py``
     - Every testcase passes and at least one testcase ran
   * - 2b
     - Verilator ``--binary``
     - ``scripts/run_svtb.py``
     - Executable exits zero and prints ``TEST PASSED``
   * - 2c
     - SymbiYosys + Z3
     - ``scripts/run_formal.py``
     - Every assertion proved by k-induction and every cover reached
   * - 3
     - Yosys
     - ``scripts/run_synth.py``
     - Design maps to the generic cell library without errors
   * - 4
     - OpenSTA
     - ``scripts/run_sta.py``
     - Worst setup and hold slack are both non-negative

Stage 2b is the Python-free path: it compiles the IP together with the
self-checking SystemVerilog testbench in ``tb/``. It exists so that every block
is provably usable on a plain SystemVerilog simulator, with no cocotb
dependency.

Stage 2c runs for the blocks that register a property wrapper; see
:doc:`verification` for what the proofs cover and how they are written.

Registering an IP
=================

An IP joins the flow with a single ``add_ip()`` call in its own
``CMakeLists.txt``. That one call creates the build targets, registers the
CTest entries and wires the fixture dependencies.

.. code-block:: cmake

   add_ip(
     NAME            fifo_sync
     TOP             fifo_sync
     SOURCES         rtl/fifo_sync.sv
     DEPENDS         cdc_sync_2ff
     COCOTB_MODULES  test_fifo_sync
     SVTB            tb/tb_fifo_sync.sv
     PARAMS          DATA_WIDTH=32 DEPTH=16
     CLOCK_PERIOD_NS 5.0
     CLOCK_PORT      clk
   )

Arguments
---------

.. list-table::
   :header-rows: 1
   :widths: 24 76

   * - Argument
     - Meaning
   * - ``NAME``
     - IP name; also the CTest suffix. Required.
   * - ``TOP``
     - Top RTL module. Defaults to ``NAME``.
   * - ``CATEGORY``
     - IP family. Defaults to the parent directory name.
   * - ``SOURCES``
     - RTL files relative to the IP directory. Required.
   * - ``DEPENDS``
     - Other registered IPs whose RTL is compiled in. Sources are flattened
       depth-first and de-duplicated, dependencies first.
   * - ``COCOTB_MODULES``
     - Python test modules in ``cocotb/``. One CTest entry per module.
   * - ``SVTB``
     - Self-checking SystemVerilog testbench, compiled with ``--binary``.
   * - ``PARAMS``
     - ``NAME=VALUE`` elaboration overrides applied to lint, simulation,
       synthesis and timing alike.
   * - ``CLOCK_PERIOD_NS``
     - Target period for static timing analysis. Defaults to 10.0.
   * - ``CLOCK_PORT``
     - Name of the clock port constrained by OpenSTA. Defaults to ``clk``.
   * - ``STA_SDC``
     - The block's constraint fragment, relative to the IP directory. The
       timing stage sources it with the instance name set to the empty
       string, so every command in it is run by OpenSTA and a command that
       tool does not have fails the stage. A block registered ``NO_STA`` gets
       a check-only test, ``sdc.<category>.<name>``, instead: every clock is
       created on the netlist, the fragment is sourced, and no slack is
       judged. What a fragment applied is written next to the report as
       ``<name>.applied.sdc``. ``ctest -L repo`` separately rejects
       Synopsys-only collection commands in every fragment.
   * - ``SDC_INST_VAR``
     - The fragment's instance variable, when it is not ``<SDC STEM>_INST``.
   * - ``SDC_VARS``
     - ``NAME=TCL`` variables set before the fragment is sourced, typically
       its clocks: ``"FIFO_RD_CLK=[get_clocks rd_clk]"``.
   * - ``SDC_CLOCKS``
     - Further clock ports for the check-only test; ``CLOCK_PORT`` is always
       the first.
   * - ``FORMAL_TOP``
     - Property wrapper module. Registers ``formal.<category>.<name>``,
       which proves every assertion in the wrapper by k-induction and
       requires every cover statement to be reached.
   * - ``FORMAL_SOURCES``
     - The wrapper's files, relative to the IP directory, conventionally
       ``formal/<name>_formal.sv``.
   * - ``FORMAL_DEPTH``
     - Induction and cover depth. Defaults to 20.
   * - ``FORMAL_MULTICLOCK``
     - Prove with free-running clocks: every clock is a free input that may
       change on any solver step. For blocks with several clocks or with
       logic on both edges.
   * - ``FORMAL_PARAMS``
     - ``NAME=VALUE`` parameters of the wrapper. ``PARAMS`` do not apply:
       proofs run at small configurations of their own.
   * - ``NO_LINT`` ``NO_SIM`` ``NO_SYNTH`` ``NO_STA``
     - Opt out of a stage. Used only where a stage is meaningless, for example
       timing analysis on a purely combinational block.

Dependency ordering
-------------------

``DEPENDS`` may only name an IP that has already been registered. The root
``CMakeLists.txt`` therefore adds categories from leaf primitives upwards:

.. code-block:: text

   cdc -> clocking -> memory -> arithmetic -> bus -> dsp
       -> ml -> crypto -> peripherals -> soc

A forward reference is a configure-time error with an explicit message rather
than a confusing link failure later on.

Out-of-source enforcement
=========================

Three independent mechanisms keep the source tree clean:

#. The root ``CMakeLists.txt`` refuses to configure if the binary directory
   equals the source directory.
#. Every driver script takes explicit ``--out-dir`` and ``--report`` paths that
   CMake always points inside ``${CMAKE_BINARY_DIR}``.
#. ``tests/test_no_source_pollution.py`` walks the repository and fails the
   regression if a waveform, netlist, log or results file is found outside
   ``build/``.

Cleaning
========

.. code-block:: bash

   cmake --build build --target clean            # Ninja's own clean
   cmake --build build --target clean-artifacts  # wipe IP, wave, report, doc output
   rm -rf build                                  # full reset, including the cache

Toolchain discovery
===================

``cmake/SocIpToolchain.cmake`` locates every external tool and never fails when
one is absent: the corresponding stage is simply not registered. This keeps the
repository usable on a machine that has, say, Verilator but not OpenSTA. The
configure summary states exactly what was found:

.. code-block:: text

   soc-ip-portfolio 0.1.0
     IPs registered : 50
     Verilator      : Verilator 5.020 2024-01-01
     Yosys          : Yosys 0.33
     OpenSTA        : /home/user/.local/bin/sta
     Formal         : /home/user/.venvs/soc-ip-portfolio/bin/yowasp-sby + z3
     cocotb python  : /home/user/.venvs/soc-ip-portfolio/bin/python (cocotb 1.9.2)
     Sphinx         : /home/user/.venvs/soc-ip-portfolio/bin/sphinx-build
     Build root     : /mnt/c/Users/user/soc-ip-portfolio/build
