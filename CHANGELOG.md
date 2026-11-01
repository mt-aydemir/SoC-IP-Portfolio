# Changelog

All notable changes to the SoC IP Portfolio as a whole are documented here.
Individual IP blocks are versioned independently and carry their own
`CHANGELOG.md`.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the repository uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`arithmetic` category: ten datapath primitives.** `adder`, `subtractor`,
  `comparator`, `barrel_shifter`, `multiplier`, `accumulator`, `mac`, `alu`,
  `divider` and `cordic`, each brought to the full per-IP layout: a
  self-checking SystemVerilog testbench, a cocotb suite with directed,
  randomised and regression tests against a reference model written from the
  specification, Sphinx documentation, a timing constraint fragment, and an
  `add_ip()` registration.
- **`peripherals` category: `gpio`, `uart`, `spi_master`, `i2c_master`.**
  Rewritten from the blocks in the original repository against the house
  style and verified to the same standard as the rest of the catalogue: a
  GPIO with synchronised inputs, atomic set/clear and edge interrupts; a UART
  with a run-time bit period, parity, and framing, overrun and break
  handling; an SPI master with run-time mode and bit order and multi-word
  chip-select frames; and an I2C master with byte-level commands, clock
  stretching and arbitration. Each suite checks the serial line itself —
  bit timing, edge counts, open-drain behaviour — against a protocol model
  written from the specification. The original SPI master produced one SCLK
  edge too few per word; reintroducing that defect fails both new suites.
  The catalogue is now 33 IPs.
- **`examples/`: two integration examples**, registered through `add_ip()` so
  they run the same flow as the IPs they use. `nco` is a quadrature oscillator
  from `accumulator` and `cordic` with quadrant folding — the local
  oscillator of a digital down-converter. `cdc_stream_bridge` carries a
  stream between unrelated clocks from one raw reset, using `cdc_reset_sync`
  and `fifo_async`, and is the reference for the wiring rules in the
  integration guide.
- **The timing stage now runs.** `setup_env.sh` builds OpenSTA (pinned by
  commit, 3.1.0) and CUDD, and in `--no-root` mode unpacks Tcl, SWIG, Bison
  and Flex from their `.deb` packages into a private sysroot, so every stage
  of the flow works without sudo.
- **`ml` category: a quantised int8 CNN inference accelerator.** Four IP
  blocks, from the processing element up to a complete accelerator:
  `systolic_pe`, `systolic_array`, `requant_int8` and `cnn_accel`. The
  accelerator is driven entirely over AXI4-Stream — every command is a
  TLAST-delimited frame, so a whole convolution layer can be queued as one
  descriptor chain with no processor involvement between tiles — and carries an
  accumulator buffer so reductions deeper than the array need no host
  arithmetic. 50 cocotb tests and four self-checking SystemVerilog testbenches.
- **`sw/cnn_accel`: a bare-metal Cortex-A53 driver.** Frame construction, an
  AXI DMA transport with the cache maintenance an A53 needs, quantisation
  preparation (scale normalisation, zero-point folding) that is bit-exact with
  the RTL, and a convolution lowered and tiled onto the accelerator. Verified
  on a host against an independent reference implementation over six layer
  geometries, which is the part of the stack the RTL regression cannot reach.
- **`fpga/zynq_ultrascale`: the Zynq UltraScale+ integration.** Tcl to package
  the accelerator as an IP integrator core and to build a reference design
  connecting it to the processing system through an AXI DMA, with the
  implementation constraints and the reasoning behind them.
- CI job running the driver self-test with the system compiler.
- Repository infrastructure: CMake + Ninja build with strict out-of-source
  enforcement, `add_ip()` registration, and CTest fixtures that order the
  lint → simulation → synthesis → timing flow.
- Flow drivers for Verilator lint, cocotb simulation, the Python-free
  SystemVerilog testbench path, Yosys synthesis and OpenSTA timing analysis.
- Shared cocotb verification library (`verification/lib/socip`): clock and
  reset helpers, strict in-order scoreboard, corner-biased random stimulus,
  and portable elaboration-parameter access.
- Repository-level regression tests for directory structure, RTL house style
  and source-tree pollution.
- IP template and `scripts/new_ip.py` generator producing a block that passes
  the full regression from the moment it is created.
- Sphinx documentation: getting started, build flow, coding style,
  verification methodology, integration guide and contributing guide, plus a
  generated IP catalogue.
- `scripts/setup_env.sh`, provisioning the complete toolchain on Ubuntu 24.04
  under WSL2, including an OpenSTA source build.

### Fixed

- **The `arithmetic` timing constraints had never been run by any tool.** No
  stage sourced the per-IP `.sdc` fragments, and all ten used Synopsys-only
  collection commands (`sizeof_collection`, `remove_from_collection`) that
  OpenSTA and Vivado reject. Their usage also built sub-instance paths by
  appending to a cell object, which no tool resolves. They now use commands
  common to all three and take the instance as a hierarchical name. The new
  `add_ip(STA_SDC ...)` makes the timing stage source a fragment, which the
  five sequential arithmetic blocks use - `mac` now reports its multiplier
  and accumulator path groups - and `repo.sdc_portable` rejects
  non-portable commands in every fragment.
- **The `cdc`, `clocking` and `memory` timing constraints were never applied
  as written.** Beyond the same Synopsys-only commands, they used
  `get_property` in OpenSTA's argument order (Vivado's is the reverse), the
  Vivado-only `-datapath_only`, Vivado's `REF_NAME` filter, and register and
  library pin names (`sync_q_reg*0*/D`, `CLR`, `C`) that Yosys does not
  produce. Several were wrong in any tool:
  - every skew bound on a crossing was overridden: `cdc_sync_2ff` declared a
    false path on the same pins, and `cdc_pulse_sync`, `cdc_handshake`,
    `fifo_async` and `clk_mux` an asynchronous clock group, both of which
    take precedence over a max-delay. The bounds now replace them, so any
    other path between the clocks is reported rather than hidden;
  - `clk_mux` declared its second generated clock with `-add` but no
    `-master_clock`, which every tool rejects, and its select and enable
    constraints missed the crossing from the other branch's synchroniser
    state; the bound is now between the two source clocks;
  - `fifo_async` bounded its memory path to a `read_data_reg` that does not
    exist (the port is `rd_data`);
  - `bram_ctrl`, `fifo_sync` and `register_file` put max-delays on
    hierarchical output pins, which constrained the integrator's logic beyond
    the block; they are path groups now;
  - `cdc_reset_sync` and `reset_controller` applied `set_max_fanout` to a
    pin, which SDC does not allow.
  All fifteen fragments, the RAMs' included, now attach to nets named after
  the block's ports and use commands common to OpenSTA, Synopsys tools and
  Vivado, with small `socip_*` procedures where the tools disagree. Every
  fragment is executed by the flow: through the timing stage, or for the
  `NO_STA` blocks a new check-only `sdc.<category>.<name>` test that creates
  every clock and sources the fragment against the netlist (`ram_dp`
  excepted, whose netlist OpenSTA cannot read). The applied constraints are
  written to `<name>.applied.sdc` for review.
- **`subtractor`: `overflow` was inverted in the unsigned configuration.** It
  was forwarded from the internal adder, whose unsigned overflow is its carry
  out — which for `a + ~b + ~borrow_in` means *no* underflow. Found by the new
  suite's independent reference model; the pre-fix RTL fails it.
- **`alu`: `SUB` ignored `carry_in`**, contradicting its own opcode table
  (`a - b - !carry_in`), so multi-word subtraction across a borrow was off by
  one. The pre-fix RTL fails four of the new tests.
- **`cordic` did not synthesise with Yosys.** Its arctangent table was an
  unpacked array `localparam`, which Verilator accepts and Yosys rejects. Now
  a `case` function.
- **`run_sta.py` would have passed every design, violations included.** Its
  slack pattern did not match OpenSTA's `worst slack max <n>` output, and an
  empty match was treated as "no timing endpoints", which passes. The pattern
  now matches both formats, and a netlist with registers but no parsed slack
  fails loudly. The stage had never run against a real OpenSTA, which is how
  this went unnoticed.
- **`run_sta.py` used Synopsys-only commands** (`remove_from_collection`,
  `sizeof_collection`) that OpenSTA does not have, and applied the setup clock
  uncertainty to hold as well — failing every self-looping register, i.e.
  every counter, on pre-layout pessimism. Hold now gets its own margin.
- **`clk_mux` could enable both clocks at once** if `select` turned back
  mid-changeover — the glitch the block exists to prevent. Its own randomised
  abuse test failed on about a third of seeds; the full regression had passed
  by luck of the seed.
- **`nco` did not synthesise**: Yosys 0.67 aborts on a `signed'()` cast used
  directly as a port connection; the casts now go through named signals.
- `requant_int8` is timed at 6.5 ns instead of 4 ns, the period its stage 3
  actually meets on the generic library, and `cnn_accel` is no longer timed:
  its flip-flop accumulator buffer gives meaningless slacks, as for `ram_sp`.
- **`setup_env.sh` cloned an OpenSTA tag that does not exist** (`v2.6.0`;
  the project publishes no tags). It now checks out a pinned commit.
