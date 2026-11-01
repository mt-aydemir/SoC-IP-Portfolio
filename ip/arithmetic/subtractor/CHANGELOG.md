# Changelog

All notable changes to `subtractor` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html):

- **major** — an incompatible change to ports, parameters or protocol
- **minor** — a backwards-compatible feature or new parameter
- **patch** — a bug fix or documentation change with no interface change

## [Unreleased]

## [1.0.0] - 2026-10-31

### Added

- Initial release.
- Parameterisable width with borrow in, borrow out and overflow.
- Signed and unsigned interpretations, selecting the overflow rule and the
  saturation limit.
- Optional saturation, clamping an unsigned result to zero and a signed one
  to the most positive or most negative value.
- Elaboration-time parameter legality checks.
- cocotb suite: identities, the borrow boundary, the signed overflow corners,
  the saturation limits, corner-biased and opposite-sign randomised operands,
  an exhaustive sweep at narrow widths, a borrow-chain regression and a
  cross-check against the equivalent addition.
- Self-checking SystemVerilog testbench with an independent reference model.
- Full documentation and a timing constraint fragment.

### Fixed

- **`overflow` was inverted in the unsigned configuration.** The flag was
  forwarded straight from the internal adder, whose unsigned overflow is its
  carry out — and a carry out of `a + ~b + ~borrow_in` means the subtraction
  did *not* go below zero. An unsigned subtraction that underflowed therefore
  reported `overflow = 0`, and one that produced a perfectly representable
  result reported `overflow = 1`. The unsigned flag is now taken from
  `borrow_out`. The signed configuration was correct and is unchanged, as is
  `difference` in both: the saturation logic already used `borrow_out` for the
  unsigned clamp, so only the flag was wrong.

  Found by the new cocotb suite, whose reference model computes the exact
  difference and asks whether it was representable instead of re-deriving it
  through the same inverted-operand identity as the design.
