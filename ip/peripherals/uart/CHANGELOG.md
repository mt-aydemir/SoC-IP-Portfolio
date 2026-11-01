# Changelog

All notable changes to `uart` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

## [1.0.0] - 2026-11-01

Replaces the earlier `peripherals/uart.sv`, which had no `rxd` synchroniser,
no stop-bit, parity or overrun handling, ignored its `PARITY` parameter and
used an active-high reset.

### Added

- Initial release.
- Full-duplex transmitter and receiver with a run-time bit period, so one
  netlist serves every baud rate and the clock-to-baud rounding stays with the
  integrator.
- 5 to 9 data bits, none / even / odd parity, one or two stop bits.
- Receiver with an `rxd` synchroniser, mid-bit sampling, start-bit glitch
  rejection, parity and framing errors reported with each character, overrun
  that keeps the unread character, and break handling that produces one
  character rather than a stream.
- Ready/valid streams on both sides.
- cocotb suite checking the transmitted line bit by bit with exact timing and
  driving the receiver asynchronously to the clock, including a 3 % baud
  error; a self-checking SystemVerilog testbench at a second geometry.
