# Changelog

All notable changes to `aes128` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

## [1.0.0] - 2026-11-01

### Added

- Initial release.
- AES-128 encryption and decryption, one round per cycle, 11 cycles per
  block, direction chosen per block.
- Key schedule computed on the fly, forward for encryption and backward
  from the last round key for decryption; a key load runs it forward once.
- `DECRYPT` parameter to leave out the inverse cipher.
- S-box ROMs generated from their FIPS-197 definition by
  `scripts/gen_sbox.py`, with a `--check` mode.
- cocotb suite against an independent FIPS-197 model, with the standard
  and AESAVS vectors, cycle counts, key handling and random round trips;
  SystemVerilog testbench with a behavioural reference.
- Documentation and timing constraints.
