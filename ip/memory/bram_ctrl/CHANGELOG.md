# Changelog

All notable changes to `bram_ctrl` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `scripts/bram_ctrl.sdc` now uses only commands common to OpenSTA, Synopsys
  tools and Vivado, and takes the instance as a hierarchical name.
- The max-delay on the `req_ready` pin constrained the integrator's logic
  beyond the block; it is a path group now.

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Block RAM controller presenting a pipelined request and response interface
  in front of ram_sp.
- Reserves a response-buffer slot before accepting a request, because a read
  issued to the RAM cannot be recalled. The two-entry buffer means a one-cycle
  consumer stall costs no throughput.
- Exactly one response per accepted request, in order, writes included, so a
  bridge in front of the block can map requests to responses one to one
  without tracking which were writes. Set WRITE_RESPONSE to 0 for a
  fire-and-forget write port.
- Out-of-range addresses are answered with rsp_err and never reach the array,
  rather than being allowed to alias onto a valid location. Silently aliasing
  a bad address turns a software bug into corrupted data somewhere unrelated.
- Assertions covering the buffer-overrun invariant, request stability while
  stalled, and response persistence until accepted.
- cocotb suite: reset state, write then read, byte-enable masking, responses
  held under back-pressure, out-of-range error reporting, randomised traffic
  with response back-pressure, sustained streaming and a mid-stream reset. Run
  at three parameter configurations.
- Self-checking SystemVerilog testbench.
- SDC fragment and full documentation.
