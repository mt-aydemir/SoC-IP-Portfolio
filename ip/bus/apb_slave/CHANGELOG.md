# Changelog

All notable changes to `apb_slave` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

### Added

- A UVM environment in `uvm/`: an APB agent, a register responder and
  monitor, and a scoreboard with functional coverage. `apb_random_test` and
  `apb_back_to_back_test` run with `REGISTERED` both 1 and 0.

## [1.0.0] - 2026-11-01

### Added

- Initial release.
- AMBA APB4 completer (`PSTRB`, `PPROT`, `PSLVERR`, `PREADY`) bridging each
  transfer onto a ready/valid register request port shared with
  `axi4_lite_slave`, with the response sampled on the accepting edge.
- `REGISTERED=0` for zero-wait combinational responses, `REGISTERED=1` for a
  registered response with one wait state; a `done` flag stops the request
  being issued twice in the completing cycle.
- Assertions on the requester's APB rules (setup then access, the transfer
  held until `PREADY`, no read strobes) and on the request's stability.
- cocotb suite with an APB4 requester and register block written from the
  specifications; self-checking SystemVerilog testbench running both modes.
- Documentation and timing constraints.
