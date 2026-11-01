# Changelog

All notable changes to `accumulator` are documented here.

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
- An accumulator wider than its input, with the growth width left to the
  caller and overflow reported so a wrong choice is visible rather than
  silent.
- Clear, load and enable with a defined priority: clear beats load beats
  accumulate, so the recovery path can never be masked.
- Signed and unsigned interpretations, selecting both the addend extension and
  the overflow rule.
- Optional saturation at the correct limit for each interpretation,
  deliberately non-latching: `overflow` describes the addition performed on
  the current edge, and a latching flag belongs to the consumer.
- Elaboration-time parameter legality checks, including that `ACC_WIDTH` is
  at least `DATA_WIDTH` so the very first addend can be represented.
- cocotb suite driven from a cycle-accurate reference model: the reset state,
  accumulation, hold, load, clear, the control priority matrix, both
  saturation limits, randomised control every cycle, totals deliberately
  pushed across a limit, a long accumulation past the data width, the
  non-sticky saturation property, and a mid-stream reset.
- Self-checking SystemVerilog testbench with a 64-bit reference total, so the
  model cannot overflow where the design does not.
- Full documentation and timing constraints.
