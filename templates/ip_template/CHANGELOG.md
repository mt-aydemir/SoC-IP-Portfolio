# Changelog

All notable changes to `template_ip` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

## [1.0.0] - 2026-01-01

### Added

- Initial release.
- Ready/valid registered stage with parameterisable `DATA_WIDTH`.
- Concurrent assertions covering payload stability and valid persistence.
- Elaboration-time parameter legality checks.
- cocotb suite: directed, randomised and regression tests.
- Self-checking SystemVerilog testbench.
- Full documentation and timing constraints.
