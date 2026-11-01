# Changelog

All notable changes to `cdc_handshake` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Four-phase request/acknowledge transfer of a multi-bit payload between two
  unrelated clock domains, with ready/valid stream interfaces on both sides.
- Payload held in a source-domain register that is written only while the
  request is low, so the destination always samples a static value and the
  data path needs no synchroniser.
- Assertions covering source payload stability while stalled, the payload
  register being held for the whole request window, and destination valid
  being held until the consumer accepts.
- Elaboration-time checks on `DATA_WIDTH` and `STAGES`.
- cocotb suite covering reset state, a single word, the source closing for the
  whole round trip, destination back-pressure, randomised streams at three
  clock ratios, order and count preservation over 300 words, and recovery
  after reset.
- Self-checking SystemVerilog testbench at a 10 ns / 23 ns clock ratio.
- SDC constraint fragment, including the payload path that crosses domains
  without a synchroniser by design.
- Full documentation.
