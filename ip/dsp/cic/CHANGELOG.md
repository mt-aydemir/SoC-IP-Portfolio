# Changelog

All notable changes to `cic` are documented here.

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
- Hogenauer CIC decimator with pipelined integrators, combs at the output
  rate and a run-time decimation rate up to `MAX_RATE`.
- Exact full-precision output; integrators wrap by design, every register at
  the output width.
- Back-pressure refuses only a sample that would produce an output while the
  output register is full.
- cocotb suite with a register-level model and an independent numpy
  moving-sum reference; self-checking SystemVerilog testbench at
  `DIFF_DELAY=2`.
- Documentation and timing constraints.
