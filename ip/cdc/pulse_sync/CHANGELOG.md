# Changelog

All notable changes to `cdc_pulse_sync` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `scripts/cdc_pulse_sync.sdc` now uses only commands common to OpenSTA, Synopsys
  tools and Vivado, and takes the instance as a hierarchical name.
- The asynchronous clock group overrode the skew bounds on both crossings;
  it is gone, and the bounds are applied through the synchronisers' input nets.

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Toggle-based event transfer between two unrelated clock domains, with a
  destination-to-source acknowledge path so that no in-flight event can be
  cancelled by the next one.
- `src_busy` back-pressure output, and an assertion that fires when a pulse is
  presented while busy rather than losing the event silently.
- Assertion checking that `dst_pulse` is never wider than one cycle.
- Elaboration-time check rejecting `STAGES < 2`.
- cocotb suite covering reset state, a single event, the busy handshake,
  randomised events, maximum-rate bursts and an event immediately after reset —
  each at three clock ratios (destination faster, slower and nearly equal).
- Self-checking SystemVerilog testbench at a 10 ns / 27 ns clock ratio.
- SDC constraint fragment.
- Full documentation.
