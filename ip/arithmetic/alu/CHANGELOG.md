# Changelog

All notable changes to `alu` are documented here.

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
- Fifteen opcodes: add and subtract with carry, the four logical operations,
  five shifts and rotates, signed and unsigned set-less-than, and two
  pass-throughs. The sixteenth encoding returns zero.
- The four condition flags Z, N, C and V, with carry following the ARM and x86
  convention (carry set means "no borrow" for subtraction), and C and V
  cleared by every non-arithmetic opcode so a consumer never reads a stale
  value.
- Built from the portfolio's single `adder` and `barrel_shifter` rather than
  its own copies.
- cocotb suite: every opcode on simple operands, flag clearing, the carry
  convention, double-width addition and subtraction chained through
  `carry_in`, the comparisons at the sign boundary where they disagree,
  corner-biased randomised operations, an exhaustive sweep at narrow widths,
  and a statelessness check.
- Self-checking SystemVerilog testbench with an independent reference model.
- Full documentation and a timing constraint fragment.

### Fixed

- **`SUB` ignored `carry_in`.** The opcode table defines `SUB` as
  `a - b - !carry_in` — the ARM `SBC` form, which is what lets a subtraction
  chain across words — but the shared adder's carry input was forced high for
  every subtracting opcode, so `SUB` always computed a plain `a - b`. A
  double-width subtraction whose low word borrowed therefore came out one too
  large in the high word. `SUB` now takes `carry_in`; `SLT` and `SLTU` still
  force it high, because a comparison is a plain `a - b` whatever the carry
  holds.

  Callers that relied on the old behaviour must drive `carry_in = 1` for a
  plain subtraction, exactly as they drive `carry_in = 0` for a plain
  addition. Recorded here rather than as a major version because the block
  had not been released: the fix brings the implementation into line with its
  own documented interface.
