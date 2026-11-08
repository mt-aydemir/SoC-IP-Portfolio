# Changelog

All notable changes to `sha256` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

### Changed

- The testbench's reference round fits in 100 columns.

## [1.0.0] - 2026-11-01

### Added

- Initial release.
- SHA-256 over a 32-bit big-endian word stream, one round per cycle,
  65 cycles per block, loading overlapped with rounds 0 to 15.
- Message padding in hardware for any byte length, the empty message and
  the spill into an extra block included; 64-bit length counter.
- A waiting digest does not block the next message until its final
  addition.
- cocotb suite against `hashlib`: the FIPS 180-4 examples, every length
  from 0 to 140 bytes, exact cycle counts, back-pressure and random
  messages; SystemVerilog testbench with the one-million-"a" vector and a
  textbook reference.
- Documentation and timing constraints.
