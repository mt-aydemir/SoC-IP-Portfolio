# Changelog

All notable changes to `cordic` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

### Fixed

- `scripts/cordic.sdc` used Synopsys-only collection commands that OpenSTA
  and Vivado reject. It now uses commands common to all three, and
  `CORDIC_INST` is the instance's hierarchical name rather than a cell
  object.

## [1.0.0] - 2026-11-01

### Added

- Initial release.
- Iterative circular CORDIC with rotation (sine, cosine) and vectoring
  (magnitude, arctangent) modes selected per operation.
- Angle format scaled by π, so a single canonical arctangent table at 31
  fractional bits serves every width from 8 to 32 exactly.
- Two guard bits on the x and y datapath to absorb the CORDIC gain.
- Convergence-range flag for rotation-mode angles.
- Ready/valid interfaces on both sides.
- Elaboration-time parameter legality checks, and a note when `ITERATIONS`
  exceeds `WIDTH`.
- cocotb suite against Python's `math` module with an LSB error bound.
- Self-checking SystemVerilog testbench against the simulator's real-valued
  math functions.
- Full documentation and timing constraints.

### Fixed

- **The block did not synthesise with Yosys.** The arctangent table was an
  unpacked array `localparam`, which is legal SystemVerilog and elaborates in
  Verilator, but which the Yosys front end rejects — so the block passed lint
  and simulation and failed the synthesis stage of the portfolio's own flow.
  The table is now a function over a `case` statement, which maps to the same
  constant ROM on every tool. Values re-verified against
  `round(atan(2**-i) / pi * 2**31)`.
- The datapath comment claimed one guard bit on `x` and `y`; there are two.
