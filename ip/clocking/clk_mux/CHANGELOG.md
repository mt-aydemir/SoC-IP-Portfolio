# Changelog

All notable changes to `clk_mux` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **Both branches could be enabled at once when `select` turned back
  mid-changeover.** Each request was qualified only with the other branch's
  falling-edge enable, so a chain that had filled but whose enable had not yet
  followed was invisible to the other branch for up to half a period. Requests
  are now qualified with the other branch's chain as well. The existing
  `test_rule_violation_never_glitches` failed on 22 of 60 seeds before the
  fix (first seen with `COCOTB_RANDOM_SEED=638582201`) and on none of 260
  after it.

## [1.0.0] - 2026-07-30

### Added

- Initial release.
- Glitch-free two-input clock multiplexer with cross-coupled per-branch
  synchronisers and falling-edge enable registers.
- `clk_active` status output reporting which clock is driving the output, so
  the integrator can honour the usage rule without guessing at the changeover
  time.
- Each branch's request chain is **cleared** rather than shifted when the
  request is withdrawn. A plain shift register would let a `1` already in
  flight reach the enable after the request had gone, so a `select` that
  toggles during a changeover could enable both branches at once — the exact
  glitch the block exists to prevent. This was caught by the block's own
  both-branches-enabled assertion during bring-up.
- Elaboration-time check rejecting `STAGES < 2`, and a runtime assertion that
  the two branches are never enabled simultaneously.
- cocotb suite covering reset selection, switching in both directions,
  back-to-back switches, randomised switching, 200 deliberate usage-rule
  violations, and a stalled source clock parking the output safely.
- Self-checking SystemVerilog testbench at 10 ns / 27 ns measuring every output
  phase for runts.
- SDC fragment declaring the asynchronous clock groups and the generated clock.
- Full documentation.
