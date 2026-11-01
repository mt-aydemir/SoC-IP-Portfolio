# Changelog

All notable changes to `ram_sdp` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `scripts/ram_sdp.sdc` now uses only commands common to OpenSTA, Synopsys
  tools and Vivado, and takes the instance as a hierarchical name.
- The clock-name comparison used OpenSTA's `get_property` argument order,
  which Vivado reverses.

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Simple dual-port synchronous RAM: one write port and one read port, each in
  its own clock domain.
- Added as an IP in its own right rather than as private storage inside the
  FIFOs, because both fifo_sync and fifo_async need exactly this block and
  duplicating it would have meant two copies of the same memory.
- Single driving process for the array, unlike a true dual-port memory, so it
  needs no lint exception and has no collision rules beyond read-first.
- cocotb suite: write and read back, byte-enable masking, concurrent access to
  different addresses, same-address collision returning old data, randomised
  traffic at three clock ratios, a full sweep and sustained concurrent
  traffic.
- Self-checking SystemVerilog testbench at a 10 ns / 17 ns clock ratio.
- SDC fragment and full documentation.
