# Changelog

All notable changes to `mac` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

### Fixed

- `scripts/mac.sdc` used Synopsys-only collection commands that OpenSTA
  and Vivado reject. It now uses commands common to all three, and
  `MAC_INST` is the instance's hierarchical name rather than a cell
  object.

## [1.0.0] - 2026-11-01

### Added

- Initial release.
- `acc <- acc + a*b` at one multiply-accumulate per cycle, built from
  `multiplier` and `accumulator` rather than reimplementing either.
- Clear alignment: `clear` is asserted with the first sample of a frame and
  delayed internally by the multiplier's latency, so it reaches the
  accumulator in the same cycle as the product it accompanies. An unaligned
  clear loses the previous frame's last term or the new frame's first one.
- The clear is implemented as a load of the first product, so starting a frame
  costs no cycle and discards no sample.
- An accumulator wider than the product, with the growth width left to the
  caller and `overflow` reported when the choice was too small.
- Signed and unsigned interpretations, and optional saturation inherited from
  the accumulator.
- Elaboration-time checks, including that `ACC_WIDTH` can represent a single
  product.
- cocotb suite driven from a cycle-accurate model of the structure: the reset
  state, the two-cycle latency counted in edges, a hand-computed dot product,
  the clear alignment across a zero-gap frame boundary, back-to-back frames,
  gaps inside a frame, random frames, independently drawn `in_valid` and
  `clear`, the accumulator limits, a mid-stream reset and a 2000-cycle run.
- Self-checking SystemVerilog testbench with the same structural reference
  model.
- Full documentation and timing constraints.
