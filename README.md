# SoC IP Portfolio

A vendor-independent SystemVerilog IP library for FPGA and ASIC development.

Every block is written to the same standard: synthesisable SystemVerilog-2017,
fully parameterised, free of vendor primitives, and verified by a flow that
runs lint, simulation, synthesis and static timing analysis in that order. An
IP that fails any stage does not ship.

| | |
|---|---|
| **Language** | SystemVerilog-2017, synthesisable subset |
| **Targets** | FPGA and ASIC — no vendor primitives, no vendor attributes |
| **Lint** | Verilator `-Wall`, zero warnings tolerated |
| **Simulation** | cocotb, plus a self-checking SystemVerilog testbench per IP |
| **Synthesis** | Yosys, mapped to a generic reference standard cell library |
| **Timing** | OpenSTA on the mapped netlist |
| **Build** | CMake + Ninja, strictly out of source |
| **Licence** | Apache-2.0 |

## Catalogue

40 IP blocks, each passing every stage of the flow, plus two integration
examples. Categories marked *planned* are registered in the build order but
not yet implemented.

```
ip/
├── cdc/          sync_2ff  reset_sync  pulse_sync  handshake
├── clocking/     clk_divider  clk_gate  clk_mux  reset_controller
├── memory/       register_file  ram_sp  ram_sdp  ram_dp  fifo_sync
│                 fifo_async  bram_ctrl
├── arithmetic/   adder  subtractor  comparator  barrel_shifter  multiplier
│                 accumulator  mac  alu  divider  cordic
├── ml/           systolic_pe  systolic_array  requant_int8  cnn_accel
├── peripherals/  gpio  uart  spi_master  i2c_master
├── bus/          apb_slave  axi4_lite_slave  axi4_stream_slice
├── dsp/          fir  cic  iir  fft
└── crypto/       planned: aes128  sha256  lfsr_rng

examples/         nco (accumulator + cordic)
                  cdc_stream_bridge (reset_sync + fifo_async)
```

## Quick start

The flow runs inside WSL2 on Ubuntu 24.04 LTS.

```bash
./scripts/setup_env.sh                    # toolchain, venv, OpenSTA
export SOC_IP_VENV="$HOME/.venvs/soc-ip-portfolio"
cmake -S . -B build -G Ninja
ctest --test-dir build --output-on-failure
```

Useful targets and filters:

```bash
cmake --build build --target lint-all     # Verilator lint, every IP
cmake --build build --target sim-all      # full simulation regression
cmake --build build --target synth-all    # Yosys synthesis, every IP
cmake --build build --target sta-all      # OpenSTA timing, every IP
cmake --build build --target docs         # Sphinx HTML documentation

ctest --test-dir build -L memory          # one category
ctest --test-dir build -R 'sim\..*fifo'   # one IP
ctest --test-dir build -j "$(nproc)"      # in parallel
```

## Repository layout

```
ip/            the IP catalogue, one directory per block
verification/  shared cocotb library: clocking, scoreboards, stimulus, BFMs
sw/            host and embedded software for the IPs that need a driver
fpga/          vendor integration: IP packaging and reference designs
docs/          Sphinx sources for the hand-written guides
examples/      integration examples wiring several IPs together
scripts/       flow drivers (lint, sim, synth, sta) and generators
templates/     the IP skeleton used by scripts/new_ip.py
tests/         repository-level structure, style and pollution checks
cmake/         add_ip() and toolchain discovery
build/         every generated file, without exception
```

`sw/` and `fpga/` are outside the vendor-independence rule that governs `ip/`,
and deliberately so: an IP that needs a driver needs one written against a real
processor, and a design that needs to be built needs a real toolchain. The rule
is that the dependency stays there. Nothing under `ip/` knows what a Zynq is.

## The flow

Each IP passes through four stages. They are wired as CTest fixtures, so the
ordering is enforced by the test runner rather than by convention: an IP is
only simulated once it lints clean, only synthesised once it simulates clean,
and only timed once it synthesises clean.

| Stage | Tool | Pass criterion |
|---|---|---|
| Lint | Verilator `--lint-only` | Zero errors **and** zero warnings under `-Wall` |
| Simulation | cocotb + Verilator | Every testcase passes, and at least one ran |
| Smoke test | Verilator `--binary` | Exits zero and prints `TEST PASSED` |
| Synthesis | Yosys | Maps to the generic cell library without errors |
| Timing | OpenSTA | Worst setup and hold slack both non-negative |

Nothing is ever written into the source tree. Three independent mechanisms
enforce that, the last of which is a regression test that fails the build if a
waveform, netlist or log appears anywhere outside `build/`.

## Every IP contains

```
ip/<category>/<ip_name>/
├── rtl/           synthesisable SystemVerilog, one module per file
├── tb/            self-checking SystemVerilog testbench
├── cocotb/        Python test modules: directed, randomised, regression
├── docs/          functional description, diagrams, parameter and port tables
├── scripts/       timing constraints and per-IP helpers
├── README.md      overview, interface summary, quick start
├── LICENSE        Apache-2.0
├── CHANGELOG.md   independently versioned, Keep a Changelog format
└── CMakeLists.txt a single add_ip() call
```

`ctest -L repo` enforces that layout, the RTL house style and the
no-pollution rule on every change.

## Adding an IP

```bash
python scripts/new_ip.py --category memory --name cache_line_buffer
```

This copies the template, renames every file and identifier, and registers the
block with the build. What it generates already passes the full regression, so
the starting point is a working IP rather than an empty directory.

## Documentation

```bash
cmake --build build --target docs
xdg-open build/docs/html/index.html
```

The guides cover [getting started](docs/source/getting_started.rst), the
[build flow](docs/source/build_flow.rst), the
[coding style](docs/source/coding_style.rst), the
[verification methodology](docs/source/verification.rst) and the
[integration rules](docs/source/integration.rst) — including the clock domain
crossing rules that are the most common source of bugs simulation does not
catch.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
