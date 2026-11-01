# Changelog

All notable changes to `multiplier` are documented here.

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
- Independent operand widths and a full-width product, so no overflow is
  possible and none is reported.
- Signed and unsigned interpretations, with both operands explicitly widened
  to the product width before multiplying so SystemVerilog's signedness rules
  cannot turn a signed multiply into an unsigned one.
- Configurable output pipeline depth, written as a loop-based shift register
  so that `LATENCY = 1` elaborates correctly.
- `in_valid` pipelined alongside the data, so the caller does not track the
  latency by hand.
- Elaboration-time parameter legality checks.
- cocotb suite: the reset state; the latency counted in clock edges; the
  identities; the four sign combinations at the extremes of the range;
  full-rate and gapped randomised traffic; an exhaustive sweep at narrow
  widths; a mid-stream reset; and a 2000-pair sustained run.
- Self-checking SystemVerilog testbench driven from an in-order queue of
  expected products, which checks pipeline ordering and latency as well as
  arithmetic.
- Full documentation and timing constraints.
