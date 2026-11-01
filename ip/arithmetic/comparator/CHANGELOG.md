# Changelog

All notable changes to `comparator` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

### Fixed

- `scripts/comparator.sdc` used Synopsys-only collection commands that OpenSTA
  and Vivado reject. It now uses commands common to all three, and
  `COMPARATOR_INST` is the instance's hierarchical name rather than a cell
  object.

## [1.0.0] - 2026-10-31

### Added

- Initial release.
- All six relational outputs produced from one shared comparison.
- Signed and unsigned ordering, selected by parameter and implemented as two
  separately typed comparisons so SystemVerilog's signedness rules cannot
  silently collapse both into the unsigned one.
- Concurrent trichotomy assertion in the RTL, so a mixed-interpretation
  integration is reported in the integrator's own simulation.
- Elaboration-time parameter legality checks.
- cocotb suite: equality, the interpretation boundary, the extremes, adjacent
  values across the sign bit, corner-biased randomised operands, one-bit
  near-miss pairs, an exhaustive sweep at narrow widths, and the trichotomy
  and antisymmetry properties.
- Self-checking SystemVerilog testbench with an independent reference model.
- Full documentation and a timing constraint fragment.
