# Changelog

All notable changes to `clk_divider` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `scripts/clk_divider.sdc` now uses only commands common to OpenSTA, Synopsys
  tools and Vivado, and takes the instance as a hierarchical name.
- The generated clock is named from the instance name, works with the block
  as the top, and the no-op odd-divisor multicycle path is removed.

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Integer clock divider with a clock-enable output (`clk_en`) and a divided
  clock output (`clk_out`).
- Exact 50% duty cycle at every `DIVISOR >= 2`, odd ratios included, by
  combining a rising-edge phase with a falling-edge phase. The even case is
  generated without the negative-edge flip-flop, so it does not pay for a
  structure it does not need.
- `DIVISOR = 1` specialised to a pass-through, with `clk_en` still qualified by
  reset so the enable behaves identically at every ratio.
- Elaboration-time check on `DIVISOR`.
- cocotb suite covering the parked state, enable rate, measured duty cycle,
  disable and re-enable, randomised enable toggling and a 200-period drift
  check. Run at both an odd and an even divisor.
- Self-checking SystemVerilog testbench measuring phases with `$realtime`.
- SDC fragment declaring the generated clock.
- Full documentation.
