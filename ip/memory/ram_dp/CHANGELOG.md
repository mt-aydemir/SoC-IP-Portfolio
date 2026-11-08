# Changelog

All notable changes to `ram_dp` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The SystemVerilog testbench has a second instance without byte enables,
  preloaded through `INIT_FILE` from `tb/ram_init.hex`. Neither the preload
  nor that byte-enable setting was tested before; code coverage showed it.
  It writes and reads the second instance from both ports.

### Fixed

- `scripts/ram_dp.sdc` now uses only commands common to OpenSTA, Synopsys
  tools and Vivado, and takes the instance as a hierarchical name.
- The clock-name comparison used OpenSTA's `get_property` argument order,
  which Vivado reverses.

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- True dual-port synchronous RAM: both ports read and write, each in its own
  clock domain.
- Collision rules documented rather than arbitrated, matching the behaviour of
  the physical macro the block maps onto. Arbitrating in RTL would produce a
  design that simulates differently from the hardware it becomes.
- Declares the only lint exception in the portfolio, -Wno-MULTIDRIVEN, in its
  CMakeLists.txt rather than as an in-source pragma. A true dual-port memory
  is written from two clocked processes by necessity, and no other formulation
  exists when the ports have independent clocks.
- cocotb suite: each port reading its own writes, cross-port visibility,
  byte-enable masking on both ports, concurrent access to different addresses,
  randomised traffic over a partitioned address space at three clock ratios,
  and a full sweep written from one port and read from the other.
- Self-checking SystemVerilog testbench at a 10 ns / 17 ns clock ratio. The
  concurrent phase is driven by two independent processes rather than a fork:
  Verilator 5.020 miscompiles a fork whose branches call automatic tasks
  containing timing controls, and the resulting model aborts at run time.
- SDC fragment and full documentation.
