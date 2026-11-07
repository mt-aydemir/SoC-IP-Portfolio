# Changelog

All notable changes to `lfsr_rng` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

### Changed

- The feedback-tap table is left out of code coverage with `verilator coverage_off`: it is
  data, not control flow. A comment-only change.

## [1.0.0] - 2026-11-01

### Added

- Initial release.
- Fibonacci LFSR with a primitive feedback polynomial for every width from
  2 to 64 (Xilinx XAPP052), period `2**WIDTH - 1`.
- `STEPS` bits per draw in one cycle, a stream output, a run-time seed
  with the zero seed replaced by 1.
- cocotb suite with a model of the recurrence and a property test that
  recovers the polynomial from the output by Berlekamp-Massey and checks
  that it is primitive; SystemVerilog testbench measuring the period of
  every width from 2 to 16 exhaustively.
- Documentation and timing constraints.
