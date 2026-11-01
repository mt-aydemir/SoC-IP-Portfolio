# Changelog

All notable changes to `barrel_shifter` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

### Fixed

- `scripts/barrel_shifter.sdc` used Synopsys-only collection commands that OpenSTA
  and Vivado reject. It now uses commands common to all three, and
  `BARREL_SHIFTER_INST` is the instance's hierarchical name rather than a cell
  object.

## [1.0.0] - 2026-10-31

### Added

- Initial release.
- Five operations in one block: logical left and right shifts, arithmetic
  right shift, and rotates in both directions.
- Unused opcodes specified as a pass-through, so the block infers no latch and
  an out-of-range operation produces a defined result.
- Rotate amounts reduced modulo `WIDTH`, which is the only definition that
  keeps a rotate reversible at a non-power-of-two width.
- Elaboration-time parameter legality checks.
- cocotb suite: every operation at zero, one and the extremes; arithmetic
  right-shift sign extension across the full amount range; the pass-through
  opcodes; corner-biased randomised vectors; an exhaustive sweep of every
  `(operation, amount)` pair; a single-bit walk; and the rotate round-trip and
  population-count identities.
- Self-checking SystemVerilog testbench whose reference model builds each
  result bit by bit from the definition of the operation, sharing nothing with
  the design's use of the shift operators.
- Full documentation and a timing constraint fragment.
