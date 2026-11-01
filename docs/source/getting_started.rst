===============
Getting Started
===============

This page takes a clean Windows 11 machine to a full regression run.

Prerequisites
=============

The flow runs inside WSL2 on Ubuntu 24.04 LTS. From an elevated PowerShell
prompt:

.. code-block:: powershell

   wsl --install -d Ubuntu-24.04

Everything from this point on happens inside the Ubuntu shell.

Toolchain
=========

``scripts/setup_env.sh`` provisions the complete toolchain and is idempotent,
so it is safe to re-run.

.. code-block:: bash

   cd /mnt/c/Users/<you>/soc-ip-portfolio
   ./scripts/setup_env.sh

It performs three steps:

#. **System packages** (requires ``sudo``): the C/C++ toolchain, CMake, Ninja,
   Verilator, Yosys, GTKWave, Graphviz and the OpenSTA build dependencies.
#. **Python virtual environment** at ``~/.venvs/soc-ip-portfolio`` containing
   cocotb, pytest and Sphinx. The system Python is never modified.
#. **OpenSTA**, built from source because Ubuntu does not package it, and
   installed into ``~/.local``.

The three steps can be run separately:

.. code-block:: bash

   ./scripts/setup_env.sh --apt-only   # system packages, needs sudo
   ./scripts/setup_env.sh --no-sudo    # virtual environment and OpenSTA only
   ./scripts/setup_env.sh --no-sta     # skip the OpenSTA source build

The script finishes by printing the version of every tool it expects to find.
Any line reading ``MISSING`` must be resolved before the build will use that
stage; a missing tool disables its stage rather than failing the configure.

Configure and build
===================

.. code-block:: bash

   export SOC_IP_VENV="$HOME/.venvs/soc-ip-portfolio"
   cmake -S . -B build -G Ninja

The configure step prints a summary of every tool it located and the number of
registered IP blocks. Build targets:

.. code-block:: bash

   cmake --build build --target lint-all    # Verilator lint, every IP
   cmake --build build --target sim-all     # cocotb regression, every IP
   cmake --build build --target synth-all   # Yosys synthesis, every IP
   cmake --build build --target sta-all     # OpenSTA timing, every IP
   cmake --build build --target docs        # Sphinx HTML documentation

Running the regression
======================

CTest is the single entry point. The stages are ordered by test fixtures, so
an IP is only simulated once it lints clean, only synthesised once it
simulates clean, and only timed once it synthesises clean.

.. code-block:: bash

   ctest --test-dir build --output-on-failure          # everything
   ctest --test-dir build -L lint                      # one stage
   ctest --test-dir build -L memory                    # one category
   ctest --test-dir build -R 'sim\.memory\.fifo_sync'  # one IP
   ctest --test-dir build -j "$(nproc)"                # in parallel

Where the output goes
=====================

Nothing is ever written into the source tree.

.. code-block:: text

   build/
   ├── ip/<category>/<ip>/lint/    Verilator lint working directory
   ├── ip/<category>/<ip>/sim/     Verilated models and cocotb run directories
   ├── ip/<category>/<ip>/synth/   Yosys netlists, statistics and logs
   ├── ip/<category>/<ip>/sta/     OpenSTA scripts
   ├── waves/<ip>/                 VCD waveforms, one per test module
   ├── reports/{lint,sim,synth,sta}/  machine-readable stage reports
   └── docs/html/                  rendered documentation

``ctest -R repo.no_source_pollution`` enforces this rule and fails the
regression if a generated file appears anywhere outside ``build/``.

Viewing waveforms
=================

Simulation writes one VCD per test module when ``SOC_IP_WAVES`` is on, which
is the default:

.. code-block:: bash

   gtkwave build/waves/fifo_sync/fifo_sync.test_fifo_sync.vcd

Adding an IP
============

``scripts/new_ip.py`` generates a complete, conforming skeleton from the
template in ``templates/ip_template``:

.. code-block:: bash

   python scripts/new_ip.py --category memory --name cache_line_buffer

The generated block already lints, simulates, synthesises and documents
cleanly, so the first commit is a working IP rather than an empty directory.
See :doc:`contributing` for what to fill in next.
