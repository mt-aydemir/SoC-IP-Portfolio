# Changelog

All notable changes to `cdc_sync_2ff` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `scripts/cdc_sync_2ff.sdc` now uses only commands common to OpenSTA, Synopsys
  tools and Vivado, and takes the instance as a hierarchical name.
- The false path on the crossing overrode its own skew bound; the bound now
  replaces it, and the crossing is named by the `d_async` net.

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Parameterisable multi-flop synchroniser: `WIDTH`, `STAGES`, `RESET_VALUE`.
- Elaboration-time check rejecting `STAGES < 2`, which would provide no
  metastability resolution time at all.
- cocotb suite covering reset state, exact propagation latency, randomised
  traffic against a shift-register model, worst-case toggling, asynchronous
  reset during traffic, and a sweep over the supported `STAGES` values.
- Self-checking SystemVerilog testbench.
- SDC constraint fragment declaring the crossing as a false path and bounding
  source-to-first-flop skew.
- Full documentation, including the usage rule that forbids multi-bit values.
