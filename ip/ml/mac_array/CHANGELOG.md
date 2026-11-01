# Changelog

All notable changes to `mac_array` are documented here.

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
- Pipelined dot-product engine: `LANES` exact products per cycle, a
  registered adder tree, accumulation over the beats of a vector ended by
  `s_last`, the accumulator wrapping modulo `2**ACC_WIDTH`.
- `A_SIGNED` and `B_SIGNED` for every combination of signed and unsigned
  operands, exact in one signed multiply per lane.
- Credit-based flow control with a `$clog2(LANES) + 3`-entry output FIFO:
  the pipeline never stalls, full rate even when every beat ends a vector,
  and no combinational path from `m_ready` to `s_ready`.
- cocotb suite against a model and `numpy.dot` at seven parameter sets;
  SystemVerilog testbench with a padded tree and a wrapping accumulator.
- Documentation and timing constraints.
