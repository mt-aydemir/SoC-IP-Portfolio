# Changelog

All notable changes to `requant_int8` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-08-02

### Added

- Initial release.
- Requantisation stage for a quantised neural network: bias, fixed-point
  scale, rounding shift, output zero point and saturating clamp, taking a
  32-bit accumulator down to an int8 activation.
- Bias, multiplier and shift are ports rather than parameters, so each output
  channel of a layer carries its own — per-channel quantisation is the normal
  case rather than an optimisation.
- Round to nearest with ties away from zero, applied once to the full-width
  product. Same rule as gemmlowp's RoundingDivideByPOT; differs by at most one
  least significant bit from a TFLite-lineage reference, which rounds twice.
- Fused activations expressed through the clamp window rather than as a mode:
  a fused ReLU is out_min raised to the output zero point.
- Per-result saturation flag, which is the cheapest way to notice that a
  layer's scales are wrong.
- Assertions on the clamp window ordering, the shift range and the output
  staying inside the window it was given.
- cocotb suite: latency, exact power-of-two scales, the rounding ties of both
  signs with hand-computed spot checks, shift of zero, both clamp edges, fused
  ReLU, zero multiplier, 6000 randomised parameter sets, full-rate results
  with every parameter changing per beat, and gapped input.
- Self-checking SystemVerilog testbench with a 64-bit reference model.
- SDC fragment and full documentation.
