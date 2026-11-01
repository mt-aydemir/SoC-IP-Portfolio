# Changelog

All notable changes to `spi_master` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

## [1.0.0] - 2026-11-01

Replaces the earlier `peripherals/spi.sv`, whose master produced only seven
SCLK edges for an eight-bit word, so a real slave missed the last bit, and
whose slave drove its registers from several always blocks.

### Added

- Initial release.
- Run-time SPI mode (`cpol`, `cpha`) and bit order, so one instance talks to
  devices in different modes.
- Exactly `2 * DATA_WIDTH` SCLK edges per word, half a period apart, with half
  a period of chip-select setup and hold.
- Multi-word chip-select frames through `s_last`, held across host gaps.
- Programmable SCLK half period, down to one clock.
- cocotb suite with a mode-aware slave model that also measures the bus
  timing; self-checking SystemVerilog testbench at a 12-bit word.
