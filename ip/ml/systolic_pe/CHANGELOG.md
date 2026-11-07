# Changelog

All notable changes to `systolic_pe` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `scripts/systolic_pe.sdc` takes the instance as a hierarchical name, uses only
  commands common to OpenSTA, Synopsys tools and Vivado, and reports its paths
  as `group_path` groups instead of with `report_timing`. It is now run by the
  timing stage.

## [1.0.0] - 2026-08-02

### Added

- Initial release.
- Weight-stationary processing element for an int8 systolic matrix-multiply
  array: one multiply-accumulate per cycle, activation passed east, partial sum
  passed south.
- Double-buffered weight register. `w_shift` moves the load chain and
  `w_commit` publishes the staged weight, so the next weight tile can be loaded
  through the array while the current one is still computing.
- Weight chain runs south to north, which is the direction that lets a host
  push weight rows in their natural order.
- Product sign-extended to the accumulator width before the add, so the one
  product that needs the full `2*DATA_WIDTH` bits — `DATA_MIN * DATA_MIN` — is
  correct.
- Assertion on partial sum overflow, which is otherwise silent corruption: a
  wrapped accumulator produces numbers that stay in range and look plausible.
- cocotb suite: reset state, single multiply-accumulate, activation hand-off,
  weight shift chain, the double buffer, the signed extremes, 2000 randomised
  operand triples against a Python model, a sustained bubble-free stream, and a
  commit landing while data is in flight.
- Self-checking SystemVerilog testbench.
- SDC fragment and full documentation.
