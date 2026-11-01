============
Contributing
============

The bar for a new IP is that it is indistinguishable from the ones already in
the catalogue: same layout, same header, same test classes, same documentation
sections.

Creating the skeleton
=====================

.. code-block:: bash

   python scripts/new_ip.py --category memory --name cache_line_buffer

This copies ``templates/ip_template``, renames every file and identifier, and
registers the block in the category's ``CMakeLists.txt``. What it generates
already lints, simulates, synthesises and documents cleanly, so the starting
point is a working IP rather than an empty directory.

Required layout
===============

``tests/test_repo_structure.py`` fails the regression if any of this is
missing:

.. code-block:: text

   ip/<category>/<ip_name>/
   ├── rtl/           synthesisable SystemVerilog, one module per file
   ├── tb/            self-checking SystemVerilog testbench
   ├── cocotb/        Python test modules, named test_*.py
   ├── docs/          reStructuredText documentation
   ├── scripts/       per-IP helper scripts (constraints, models, generators)
   ├── README.md      overview, interface summary, quick start
   ├── LICENSE        Apache-2.0
   ├── CHANGELOG.md   Keep a Changelog format, semantic versioning
   └── CMakeLists.txt a single add_ip() call

Definition of done
==================

An IP is finished when all of the following hold:

#. **Lint** is clean under ``-Wall`` with no waivers.
#. **Both testbenches** pass: the cocotb suite and the SystemVerilog smoke
   test.
#. The cocotb suite contains **directed, randomised and regression** tests, and
   the randomised tests compare against a reference model.
#. **Synthesis** completes and the design maps to the generic cell library
   without inferred latches.
#. **Timing** closes at the documented clock period, where the block has
   clocked endpoints.
#. **Documentation** contains all six required sections listed below.
#. The **CHANGELOG** has an entry, and the version is bumped.
#. Nothing generated appears outside ``build/``.

Documentation sections
======================

``docs/index.rst`` for an IP must contain, in this order:

#. **Functional description** — what the block does and the algorithm it uses.
#. **Block diagram** — an ASCII or Graphviz diagram of the internal structure.
#. **Timing diagram** — a WaveDrom-style or ASCII waveform of the main
   transaction types, including the back-pressure case.
#. **Parameter table** — name, type, default, legal range, effect.
#. **Interface description** — every port: direction, width, clock domain,
   meaning.
#. **Usage examples** — an instantiation with realistic parameters, and the
   integration notes an engineer needs in order to get it right first time.

Checks that run on every change
===============================

.. code-block:: bash

   ctest --test-dir build -L repo   # structure, style and pollution checks

``repo.structure``
   Every IP directory is complete.

``repo.rtl_style``
   One module per file, module name equals file name, SPDX header present,
   ``\`default_nettype`` set and restored, no vendor primitives, no unfinished
   work markers, no tabs, no line over 100 columns.

``repo.no_source_pollution``
   No waveform, netlist, log or results file anywhere outside ``build/``.

Versioning
==========

Each IP is versioned independently with semantic versioning, recorded in its
own ``CHANGELOG.md``:

* **major** — an incompatible change to ports, parameters or protocol;
* **minor** — a backwards-compatible feature or new parameter;
* **patch** — a bug fix or documentation change with no interface change.

Commit messages
===============

.. code-block:: text

   <category>/<ip>: <imperative summary under 72 characters>

   Why the change was needed, and anything an integrator must know. Reference
   the test that now covers the behaviour.

For example::

   memory/fifo_async: fix pointer comparison at DEPTH=2

   The Gray-coded full comparison assumed at least two pointer bits, so a
   two-entry FIFO reported full one entry early. Covered by the new
   test_depth_two regression case.
