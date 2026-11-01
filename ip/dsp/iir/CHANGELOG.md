# Changelog

All notable changes to `iir` are documented here.

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
- Direct-form-I biquad, one sample per cycle, with five run-time
  coefficients in Q format.
- Exact five-product sum, rounding half up, saturation of the output and of
  the fed-back state, and a per-sample `m_saturated` flag.
- cocotb suite with a bit-exact model and an RBJ low-pass checked against
  floating point within the rounding-noise bound through 1/A(z);
  self-checking SystemVerilog testbench with and without fractional bits.
- Documentation and timing constraints.
