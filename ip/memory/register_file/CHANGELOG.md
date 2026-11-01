# Changelog

All notable changes to `register_file` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `scripts/register_file.sdc` now uses only commands common to OpenSTA, Synopsys
  tools and Vivado, and takes the instance as a hierarchical name.
- The max-delay on the read-data pins is now the path group its comment
  always described.

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Multi-port register file: one synchronous write port and a parameterisable
  number of asynchronous read ports.
- Optional hardwired zero register (RISC-V convention) and optional
  read-during-write bypass, evaluated per read port.
- Address range guard generated rather than written as a plain comparison.
  A cast of NUM_REGS to the address width wraps to zero when NUM_REGS is a
  power of two, which would have made the guard permanently false and silently
  discarded every write. Caught during bring-up at the default NUM_REGS of 32.
- Elaboration-time parameter checks and an out-of-range write assertion.
- cocotb suite: reset state, write then read, register zero, the
  read-during-write bypass, read-port independence, 1500 cycles of randomised
  traffic against a dictionary model, and a full sweep of every register.
- Self-checking SystemVerilog testbench.
- SDC fragment and full documentation.
