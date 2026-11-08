# Changelog

All notable changes to `ram_sp` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The SystemVerilog testbench has a second instance without byte enables,
  preloaded through `INIT_FILE` from `tb/ram_init.hex`. Neither the preload
  nor that byte-enable setting was tested before; code coverage showed it.

### Fixed

- `scripts/ram_sp.sdc` now uses only commands common to OpenSTA, Synopsys
  tools and Vivado, and takes the instance as a hierarchical name.
- Usage now takes the instance as a hierarchical name.

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Single-port synchronous RAM with byte enables and an optional output
  register, written as an inferable array with no vendor primitive and no
  ram_style attribute.
- Read-first behaviour on a coincident read and write, chosen because it is
  the one semantic every target can implement. Write-first is deliberately not
  offered: a parameter that silently changes meaning between targets is worse
  than no parameter.
- No reset on the array or the output register, so the memory infers as a
  block RAM rather than a wall of flip-flops. The rst_n port was removed
  entirely rather than left unused.
- Boolean parameters typed int unsigned rather than bit: a one-bit parameter
  overridden from a tool command line receives a 32-bit literal and warns on
  every build, which the zero-warning lint policy would fail.
- Address range guard generated to avoid the power-of-two wrap described in
  the register_file changelog.
- cocotb suite: write and read back, byte-enable masking, read-during-write,
  the enable holding the output, randomised traffic against a dictionary
  model, a full sweep and the address boundaries. Run at three parameter
  configurations.
- Self-checking SystemVerilog testbench.
- SDC fragment and full documentation.
