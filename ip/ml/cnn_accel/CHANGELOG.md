# Changelog

All notable changes to `cnn_accel` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this IP is versioned independently under
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `scripts/cnn_accel.sdc` takes the instance as a hierarchical name, uses only
  commands common to OpenSTA, Synopsys tools and Vivado, and reports its paths
  as `group_path` groups instead of with `report_timing`. It is now run by the
  timing stage, as a check-only test because the block is `NO_STA`.

## [1.0.0] - 2026-08-02

### Added

- Initial release.
- Quantised int8 CNN inference accelerator: `systolic_array` for the matrix
  product, an accumulator buffer for reductions deeper than the array, and one
  `requant_int8` per output channel.
- Driven entirely over AXI4-Stream, with no register interface: every command
  is a TLAST-delimited frame, so a whole layer can be queued as one
  scatter-gather descriptor chain and run with no processor involvement
  between tiles.
- Commands NOP, LOAD_WEIGHTS, LOAD_PARAMS, COMPUTE and STATUS, with the
  accumulation chunk expressed as first and last flags on COMPUTE.
- Accumulator buffer of ACC_DEPTH vectors by ARRAY_N channels, with the
  read-add-write cycle arranged so that the read and the write are permanently
  one address apart and no hazard logic is needed.
- Credit-based admission: an activation is only accepted when the output
  buffer already has room for the result it will produce, which is what allows
  the array and the requantiser to be unstallable fixed-latency pipelines.
  Elaboration check that OUT_FIFO_DEPTH exceeds the pipeline latency, since a
  shallower buffer would deadlock.
- Weight rows are accepted while the previous frame is still draining, so the
  array's double-buffered weight registers hide the drain entirely in the
  normal load-compute-load-compute sequence.
- Error handling for every malformed frame: unknown opcode, weight and
  parameter frames of the wrong length, compute frames longer or shorter than
  their header claims, and accumulation chunks whose tiles disagree on batch
  length. A weight frame of the wrong length is refused rather than half
  loaded. NOP acknowledges the sticky error.
- STATUS reply reporting the array geometry, so a mismatch between the
  bitstream and the driver is detectable at start-up rather than as garbage
  results, plus the job and vector counters and a sticky saturation flag.
- Interrupt on the last beat of an output frame being taken by the consumer.
- cocotb suite: identity layer, single-tile and three-tile GEMMs against a
  model of the whole datapath, fused ReLU, per-channel parameters, interrupt
  and counters, twelve random layers, back-pressure at 30% ready, a measured
  and bounded throughput test, a full accumulator buffer, and five malformed
  frames each followed by a good job.
- Self-checking SystemVerilog testbench at 8 by 8.
- SDC fragment and full documentation.
