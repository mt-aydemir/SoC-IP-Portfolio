# Changelog

All notable changes to `axi4_lite_slave` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

### Added

- A UVM environment in `uvm/`: an AXI4-Lite agent whose driver pipelines
  AW/W while a B response is owed, a register responder and monitor, and a
  scoreboard with functional coverage. Tests: `axil_random_test` and
  `axil_saturation_test`.

### Changed

- UVM constraint names end in `_c`, and the formal wrapper's payload
  functions fit in 100 columns.

## [1.0.0] - 2026-11-01

### Added

- Initial release.
- AMBA AXI4-Lite subordinate with independent AW, W and AR holding
  registers, accepting a write's address and data in either order, and
  registered B and R channels: no combinational path from any AXI input to
  any AXI output.
- The same ready/valid register request port as `apb_slave`; SLVERR from
  `reg_error`.
- One write and one read in flight; the request choice is locked while it
  waits, and neither direction can starve the other.
- Assertions on the manager's channel rules and on every output's stability.
- cocotb suite with a five-channel manager and register block written from
  the specifications; self-checking SystemVerilog testbench with independent
  channel processes.
- Documentation and timing constraints.
