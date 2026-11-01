# Changelog

All notable changes to `divider` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

### Fixed

- `scripts/divider.sdc` used Synopsys-only collection commands that OpenSTA
  and Vivado reject. It now uses commands common to all three, and
  `DIVIDER_INST` is the instance's hierarchical name rather than a cell
  object.

## [1.0.0] - 2026-11-01

### Added

- Initial release.
- Sequential restoring division, one quotient bit per cycle, with the trial
  subtraction and the comparison sharing one adder.
- Quotient and remainder in one operation, signed or unsigned, following the
  truncated convention of C and SystemVerilog.
- Division by zero flagged and completed without iterating, returning an
  all-ones quotient and the dividend as the remainder.
- most-negative / −1 flagged as an overflow rather than wrapping silently.
- Ready/valid interfaces on both sides, with concurrent assertions on operand
  stability and result persistence.
- Elaboration-time parameter legality checks.
- cocotb suite: the directed corners, randomised operands against a reference
  adjusted to the truncated convention, an exhaustive sweep at narrow widths,
  back-to-back requests and the division identity.
- Self-checking SystemVerilog testbench including a stalled presentation.
- Full documentation and timing constraints.
