# Changelog

All notable changes to `fifo_async` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Asynchronous FIFO with Gray-coded pointer crossings, ready/valid interfaces
  and first-word-fall-through.
- Built on ram_sdp and cdc_sync_2ff rather than reimplementing either.
- Pointers carry one guard bit above the address so that full and empty are
  distinguishable. DEPTH must be a power of two, checked at elaboration,
  because Gray coding relies on the counter wrapping exactly at the top of its
  range: a counter that wraps early produces adjacent codes differing in more
  than one bit and the whole guarantee collapses.
- Two-entry show-ahead output stage in the read domain, so total capacity is
  DEPTH + 2. wr_full refers to the RAM, which is what the writer needs to
  know.
- Level outputs are conservative by construction in both domains: a stale
  synchronised pointer can only make the FIFO look fuller to the reader and
  emptier to the writer, never the reverse.
- cocotb suite: reset state, a single word, filling to capacity, draining in
  order, randomised streams at three clock ratios, sustained full-rate traffic
  in each direction, twenty full pointer wraps, and recovery after reset. Run
  at depths 16 and 4.
- Self-checking SystemVerilog testbench at a 10 ns / 23 ns clock ratio.
- SDC fragment and full documentation.
