# Changelog

All notable changes to `systolic_array` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `scripts/systolic_array.sdc` takes the instance as a hierarchical name, uses only
  commands common to OpenSTA, Synopsys tools and Vivado, and reports its paths
  as `group_path` groups instead of with `report_timing`. It is now run by the
  timing stage. The Vivado-only DSP count is gone.

## [1.0.0] - 2026-08-02

### Added

- Initial release.
- ROWS by COLS weight-stationary systolic array of `systolic_pe` elements,
  computing one tile of a matrix product at one activation vector per cycle.
- Input skew and output deskew inside the block, so the interface is a plain
  vector in, vector out with a flat latency of ROWS + COLS - 1 rather than one
  that exposes the wavefronts to its user.
- Weight rows enter at the south edge in natural order, row 0 first, and the
  double-buffered elements allow the next tile to be pushed through the array
  while the current one is still computing.
- `busy` covers the whole pipeline, from admission to the last result, which
  is what a caller needs to know when publishing a new tile is safe.
- Idle cycles inject a zero activation vector rather than holding the previous
  one, so gaps in the input stream cost nothing and waveforms stay readable.
- Elaboration check that ACC_WIDTH can hold a full column sum, and assertions
  on committing while busy and on loading a weight row during compute.
- cocotb suite: latency, identity tile, hand-computed vector, signed extremes,
  cycle-by-cycle `busy`, 20 random tiles against a Python matrix multiply, a
  batch with 30% gaps, 500 vectors at full rate, a double-buffered tile load
  overlapping a batch, and three consecutive tiles.
- Self-checking SystemVerilog testbench at 8 by 8.
- SDC fragment and full documentation.
