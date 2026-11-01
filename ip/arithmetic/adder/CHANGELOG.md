# Changelog

All notable changes to `adder` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

## [1.0.0] - 2026-10-31

### Added

- Initial release.
- Parameterisable width with carry in, carry out and overflow.
- Signed and unsigned interpretations, selecting the overflow rule.
- Optional saturation clamping to the correct limit for each interpretation.
- Elaboration-time parameter legality checks.
- cocotb suite: directed identities and carry boundaries, the four signed
  overflow corners, saturation limits, corner-biased and same-sign randomised
  operands, an exhaustive sweep at narrow widths and a carry-chain regression.
- Self-checking SystemVerilog testbench with an independent reference model.
- Full documentation and a timing constraint fragment.
