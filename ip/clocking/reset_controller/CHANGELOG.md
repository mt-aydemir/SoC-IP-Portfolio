# Changelog

All notable changes to `reset_controller` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `scripts/reset_controller.sdc` now uses only commands common to OpenSTA, Synopsys
  tools and Vivado, and takes the instance as a hierarchical name.
- The delegated reset-synchroniser constraints now receive an instance
  name, and `set_max_fanout` on a pin is now a note for the integrator.

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Reset source combining, minimum assertion stretching, synchronous release and
  sequenced staged release for one clock domain.
- Release synchronisation delegated to `cdc_reset_sync` rather than
  reimplemented.
- `reset_active` status output.
- Elaboration-time checks on `NUM_STAGES`, `MIN_ASSERT_CYCLES` and
  `SYNC_STAGES`, and pairwise assertions checking that stages never release out
  of order. The assertions are generated pairwise so they remain valid at
  `NUM_STAGES = 1`.
- cocotb suite covering assertion while held, staged release spacing, the
  minimum assertion stretch from a one-cycle request, asynchronous assertion
  away from a clock edge, randomised software resets and a repeatability check
  over twelve consecutive resets.
- Self-checking SystemVerilog testbench with a continuous release-order
  monitor.
- SDC fragment.
- Full documentation.
