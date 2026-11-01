# Changelog

All notable changes to `cdc_reset_sync` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Asynchronous-assert / synchronous-release reset synchroniser with
  parameterisable chain depth `STAGES`.
- Elaboration-time check rejecting `STAGES < 2`, which would leave the release
  edge with no metastability resolution time.
- Assertion checking that the output never releases while the raw input is
  still asserted, which would mean the chain had been optimised away.
- cocotb suite covering held-low behaviour, exact release latency,
  asynchronous assertion away from a clock edge, sub-cycle glitch capture,
  randomised assertion phases and back-to-back assert/release cycles.
- Self-checking SystemVerilog testbench.
- SDC constraint fragment.
- Full documentation.
