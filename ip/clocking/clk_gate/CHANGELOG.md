# Changelog

All notable changes to `clk_gate` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `scripts/clk_gate.sdc` now uses only commands common to OpenSTA, Synopsys
  tools and Vivado, and takes the instance as a hierarchical name.
- The enable and `test_en` constraints go through nets rather than to
  hierarchical input pins.

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Latch-based glitch-free clock gate, inferable by any synthesiser and free of
  vendor primitives.
- `test_en` input forcing the gate open for scan test.
- Runtime assertion that `gated_clk` never rises without the enable latched
  high, which fails loudly if the latch is ever optimised into a flip-flop or
  removed.
- cocotb suite that measures the width of every gated pulse rather than
  counting edges: no edges while disabled, one gated edge per source edge while
  enabled, `test_en` behaviour, the enable changed mid-high-phase, randomised
  enable phases, and a 1000-cycle regression.
- Self-checking SystemVerilog testbench measuring every pulse with `$realtime`.
- SDC fragment declaring the generated clock and preserving the latch.
- Full documentation.
