# Changelog

All notable changes to `fir` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

## [1.0.0] - 2026-11-01

### Added

- Initial release.
- Transposed-form FIR, one sample per cycle, with one multiplier and one
  adder on the longest path for any number of taps.
- Run-time coefficient write port; a documented contract for writes during a
  stream; out-of-range addresses ignored.
- Exact output, `DATA_WIDTH + COEF_WIDTH + $clog2(TAPS)` bits, the
  most-negative corner included.
- cocotb suite with a model written from the coefficient contract, checks
  against `numpy.convolve` and a quantised low-pass response; self-checking
  SystemVerilog testbench at a non-power-of-two tap count.
- Documentation and timing constraints.
