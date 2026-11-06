# Changelog

All notable changes to the SoC IP Portfolio as a whole are documented here.
Individual IP blocks are versioned independently and carry their own
`CHANGELOG.md`.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
the repository uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A UVM stage, and UVM environments for `apb_slave` and `axi4_lite_slave`.**
  `add_ip(UVM_TOP ...)` builds a UVM 1800.2-2020 testbench once per parameter
  configuration and runs each test in it, on Verilator 5.052 or later with
  the UVM 2020-3.2 kit Verilator ships; `setup_env.sh --uvm` builds that
  Verilator beside the flow's own, without root. Each environment has a bus
  agent driven by constrained-random items, a reactive register block, a
  scoreboard that pairs every bus transaction with exactly one register
  request and predicts every read from a reference memory, and a
  covergroup. Random tests reach full coverage; back-to-back tests check the
  exact transfer timing. Six injected bugs all fail the UVM tests.
- **Formal proofs for the CDC and clocking blocks.** `add_ip(FORMAL_MULTICLOCK)`
  proves a block with its clocks as free inputs, so every ratio and phase
  between clocks is explored and every input change lands on both sides of
  every edge - the old-or-new outcome a synchroniser relies on metastability
  to resolve to. Proved: `cdc_sync_2ff` and `cdc_reset_sync` latency and
  asynchronous behaviour; `cdc_pulse_sync` one pulse per event with
  independent resets; `cdc_handshake` ordered, intact delivery with the
  payload stable while sampled; `clk_gate` and `clk_mux` glitch-free, every
  output pulse a whole high phase of one clock; `clk_divider` a 50% duty
  cycle at odd and even divisors; `reset_controller` the exact release cycle
  of every stage. Sixteen injected bugs, among them a gate without its latch
  and a mux enable on the wrong edge, all fail their proofs. Twenty blocks
  now carry proofs.
- **A formal stage: SymbiYosys proofs for twelve blocks.** `add_ip(FORMAL_TOP
  ...)` registers `formal.<category>.<name>`, which proves every assertion
  in the block's property wrapper by k-induction and requires every cover
  to be reached, so a proof under assumptions that exclude the interesting
  behaviour fails. Wrappers constrain inputs to the interface protocol,
  check results at the ports against references written from the headers,
  and reach internal state through probe wires that `run_formal.py` joins
  to the flattened design, since the free Yosys frontend has no
  hierarchical references; the RTL carries no formal code. Proved: the
  five combinational arithmetic blocks by exhaustive equivalence, the
  multiplier pipeline, `fifo_sync` (order, level, flags), all five
  `axi4_stream_slice` modes, both `apb_slave` modes, `axi4_lite_slave`,
  `mac_array` (complete equivalence with its flow control) and `lfsr_rng`.
  A mutation campaign of 26 bugs failed every proof. The no-root setup gets
  SymbiYosys from yowasp-yosys and Z3 from the z3-solver wheel; the stage
  takes about 30 seconds.
- **`ml/mac_array`, the last block of the original tree.** A pipelined
  dot-product engine: `LANES` exact products per cycle, any mix of signed
  and unsigned operands (uint8 activations against int8 weights included),
  a registered adder tree, and accumulation over the beats of a vector of
  any length. It complements `systolic_array` for layers with no weight
  reuse. Flow control is by credits into a small output FIFO, so the
  pipeline never stalls and `m_ready` reaches neither `s_ready` nor the
  pipeline; a first version that stalled every register from `m_ready`
  missed timing at 5 ns and was replaced. Checked against a model and
  `numpy.dot` at seven parameter sets, and in the SV testbench at a padded
  tree with a wrapping accumulator. Of ten injected mutants nine are caught;
  the tenth was equivalent, exposing a redundant gate that was removed. The
  catalogue is now 44 IPs and the original README tree is complete.
- **`crypto` category: `lfsr_rng`, `sha256`, `aes128`.** A maximal-length
  LFSR with a primitive polynomial for every width from 2 to 64 and any
  number of bits per draw; a SHA-256 core over a 32-bit word stream that pads
  messages of any byte length in hardware and overlaps loading with the
  first sixteen rounds, 65 cycles per block; and an AES-128 core that
  encrypts and decrypts, chosen per block, in eleven cycles, with the key
  schedule computed on the fly forward and backward and S-box ROMs
  generated from their FIPS-197 definition. Every check rests on something
  the design does not share: the LFSR's polynomial is recovered from its
  output by Berlekamp-Massey and proven primitive, and its period measured
  exhaustively for every width up to 16; SHA-256 against `hashlib`, the
  published FIPS 180-4 digests (the million-"a" message included) and a
  textbook reference; AES against the FIPS-197 and AESAVS vectors and two
  independent models with their own S-boxes. A mutation campaign confirmed
  each suite catches injected bugs. The catalogue is now 43 IPs.
- **`dsp` category: `fir`, `cic`, `iir`, `fft`.** A transposed-form FIR with
  run-time coefficients and an exact output; a Hogenauer CIC decimator with a
  run-time rate whose integrators wrap by design; a direct-form-I biquad with
  rounding, saturation of the fed-back state and a clip flag; and a burst
  radix-2 FFT/IFFT with a generated quarter-wave twiddle ROM. Each is
  bit-exact against a reference model written from its header, and each has
  an independent check that shares nothing with that model:
  `numpy.convolve`, numpy moving sums, a floating-point biquad within the
  rounding-noise bound through 1/A(z), and both `numpy.fft` and a direct
  DFT in the SV testbench. The catalogue is now 40 IPs.
- **`bus` category: `apb_slave`, `axi4_lite_slave`, `axi4_stream_slice`.**
  The two register slaves bridge APB4 and AXI4-Lite onto one shared
  ready/valid register request port, so register logic written once sits
  behind either bus. `apb_slave` has a zero-wait combinational mode and a
  registered mode; `axi4_lite_slave` handles its five channels
  independently, has no combinational path from any AXI input to any
  output, and alternates reads and writes under saturation without arbiter
  state. `axi4_stream_slice` is a register slice in five modes - bypass,
  forward, reverse, full (skid buffer) and light - carrying every
  AXI4-Stream sideband. Each suite drives the bus from a model written from
  the AMBA specification; the APB and stream SV testbenches run every mode
  side by side, and a mutation campaign confirmed each suite catches
  injected protocol bugs. The catalogue is now 36 IPs.
- The IP template's constraint fragment is portable and sourced by the
  timing stage, and `new_ip.py` now substitutes the template's upper-case
  identifier, which it used to leave as `TEMPLATE_IP` in every new block.
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

- **cocotb simulation failed with a Verilator built from source.**
  `run_cocotb.py` set `VERILATOR_ROOT` to an empty value when it was unset; the
  packaged Verilator tolerates that, but a source-built one then looks for
  `/verilator_bin`. The driver now leaves the variable unset, and every
  Verilator finds its own files.
- **A fresh clone failed the documentation build.** `docs/source/_static` was
  an empty directory, which git does not record, so Sphinx's `-W` turned the
  missing `html_static_path` into an error in every checkout but the one it
  was written in. The directory now holds a `.gitkeep`.
- **The flow can run from a path that contains spaces.** GNU Make, and so
  Verilator, cannot build in such a directory, and the drivers' `resolve()`
  calls followed any space-free symlink straight back to it. The drivers now
  make paths absolute without resolving symlinks, and the getting-started
  guide describes the relative symlink and out-of-tree build that a path with
  spaces needs.
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
