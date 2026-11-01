# Changelog

All notable changes to `gpio` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

## [1.0.0] - 2026-11-01

Replaces the earlier `peripherals/gpio.sv`, which had no input path (`pin_in`
was unused), no synchroniser and no interrupts.

### Added

- Initial release.
- Per-pin direction with output value and enable kept separate, so a value can
  be preloaded before a pin becomes an output.
- Atomic `OUT_SET` / `OUT_CLR`, removing the read-modify-write race between
  two agents driving different pins.
- Synchronised inputs through `cdc_sync_2ff`, one synchroniser per pin.
- Rising and falling edge interrupts with per-pin enables, a write-1-to-clear
  status register in which an event beats a simultaneous clear, and a level
  `irq`.
- cocotb suite against a cycle-accurate model written from the register map,
  and a self-checking SystemVerilog testbench.
