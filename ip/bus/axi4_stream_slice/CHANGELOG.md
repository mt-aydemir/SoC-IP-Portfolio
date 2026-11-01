# Changelog

All notable changes to `axi4_stream_slice` are documented here.

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
- AMBA AXI4-Stream register slice with five modes: `BYPASS`, `FORWARD`
  (registered TVALID and payload), `REVERSE` (registered TREADY), `FULL`
  (both, with a skid register, at full throughput) and `LIGHT` (both, one
  register, half throughput).
- Every AXI4-Stream signal carried: TDATA, TSTRB, TKEEP, TLAST, TID, TDEST
  and TUSER.
- Assertions on input and output beat stability.
- cocotb suite checking order, every sideband, latency, throughput, stall
  capacity and that the paths each mode cuts really are cut; self-checking
  SystemVerilog testbench running all five modes side by side.
- Documentation and timing constraints.
