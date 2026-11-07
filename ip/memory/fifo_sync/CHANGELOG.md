# Changelog

All notable changes to `fifo_sync` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Draining from the RAM ran at two thirds of the claimed rate: the prefetch
  did not count the word leaving the output stage in the same cycle, so 16
  words took 23 cycles. It does now. `test_full_rate_streaming` measures its
  rate, and the new `test_drain_rate` covers the drain.
- `p_no_underflow` was declared but never asserted, and as written it was
  false while a RAM read is in flight. It now states that a word on offer is
  a word held, and is asserted.
- `scripts/fifo_sync.sdc` now uses only commands common to OpenSTA, Synopsys
  tools and Vivado, and takes the instance as a hierarchical name.
- The max-delays on the `s_ready` and `m_valid` pins constrained the
  integrator's logic beyond the block; they are path groups now.

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Synchronous FIFO with ready/valid interfaces, first-word-fall-through, and
  programmable almost-full and almost-empty flags.
- Storage is a ram_sdp instance, so the FIFO costs one block RAM rather than
  DEPTH by DATA_WIDTH flip-flops.
- Two-entry show-ahead output stage, which is what allows a sustained one word
  per cycle in both directions at once. A single entry would force the
  prefetch to stall whenever the output was occupied, halving throughput.
- Write bypass: with the RAM empty and no read in flight, an incoming word
  goes straight to the output stage, taking the empty-FIFO latency from three
  cycles to one. Suppressed whenever anything is ahead of it, so order is
  always preserved.
- Capacity is exactly DEPTH words counting both the RAM and the output stage,
  so the level output reports what a consumer can actually still read.
- Assertions covering overflow, output-stage overrun, the level bound and
  payload stability while stalled.
- cocotb suite: reset state, measured first-word-fall-through latency, filling
  to exactly DEPTH, draining in order, the almost flags checked at every
  level, 500 words of randomised traffic, 1000 words at full rate, the FIFO
  held full and then drained, and a mid-stream reset. Run at depths 16, 5 and
  2.
- Self-checking SystemVerilog testbench.
- SDC fragment and full documentation.
