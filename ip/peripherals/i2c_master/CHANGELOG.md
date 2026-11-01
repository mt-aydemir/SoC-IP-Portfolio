# Changelog

All notable changes to `i2c_master` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

## [1.0.0] - 2026-11-01

New. The earlier repository listed `i2c_master.sv` in its tree but had no
implementation.

### Added

- Initial release.
- Byte-level command interface (START, STOP, WRITE, READ) with one response
  per command, covering register pointers, repeated starts and 10-bit
  addressing without device knowledge in the block.
- Open-drain outputs as registered enables, synchronised line inputs.
- Clock stretching: a released SCL phase does not count until the line is seen
  high.
- Multi-master arbitration with immediate release of both lines on loss.
- cocotb suite with an open-drain bus, an EEPROM-style slave and a line timing
  monitor; self-checking SystemVerilog testbench with its own slave.
