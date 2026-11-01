# cnn_accel

Quantised int8 CNN inference accelerator: a systolic matrix-multiply array with
an output accumulator buffer and per-channel requantisation, driven entirely
over AXI4-Stream.

| | |
|---|---|
| **Category** | `ml` |
| **Top module** | `cnn_accel` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | `2*ARRAY_N + 4` cycles (36 at the default size) |
| **Throughput** | one activation vector per cycle; measured 1.145 cycles/vector over a 256-vector batch |
| **Depends on** | `systolic_array`, `requant_int8`, `fifo_sync`, `ram_sdp` |
| **Licence** | Apache-2.0 |

## What it is

A host — on the reference platform a bare-metal Cortex-A53 driving an AXI DMA —
streams a weight tile, the requantisation parameters and a batch of activation
vectors, and receives a batch of int8 results. The block computes tiles of the
matrix product a convolution becomes once lowered to a GEMM.

## No register interface, and why

Every command is a frame on the data stream: a header beat, then its payload,
delimited by `TLAST`.

A convolution layer is dozens or hundreds of tiles. Driven through control
registers, the processor would have to be involved between every one of them —
and at 250 MHz a 256-vector tile takes about a microsecond, which is the same
order as an interrupt round trip on a bare-metal A53. The processor, not the
array, would set the layer's execution time.

With the commands in the stream, a whole layer is **one scatter-gather
descriptor chain**. The DMA walks it to completion and the processor is
untouched from the start of the layer to the end of it.

## Frame format

```
header beat
  [ 7: 0]  opcode      0x00 NOP  0x01 LOAD_WEIGHTS  0x02 LOAD_PARAMS
                       0x03 COMPUTE  0x04 STATUS
  [ 9: 8]  flags       COMPUTE: bit 0 = first tile, bit 1 = last tile
  [31:16]  count       payload beats the header claims
  [39:32]  out_zero_point   LOAD_PARAMS only
  [47:40]  out_min          LOAD_PARAMS only
  [55:48]  out_max          LOAD_PARAMS only
```

## The accumulator buffer

The array reduces over `ARRAY_N` terms; a real layer reduces over hundreds.
Results land in a buffer indexed by position within the batch, and each tile
adds into it — `first` overwrites instead of adding, `last` requantises and
emits. Accumulating on the host instead would put a scalar core in the path of
256 multipliers and move int32 partial sums across the bus instead of int8
results.

## Flow control

The array and requantiser cannot be stalled, so the block refuses to admit an
activation unless the output buffer already has room for the result arriving
`TOTAL_LATENCY` cycles later. One counter does the accounting. `OUT_FIFO_DEPTH`
must exceed the pipeline latency — an elaboration check enforces it, because a
shallower buffer deadlocks.

## Error handling

`TLAST` is the delimiter, `count` is the check. Where they disagree `TLAST`
wins and a sticky error is raised. A **weight frame of the wrong length is not
committed at all**: half a tile is misaligned rather than incomplete, and
computing with it would give numbers that look almost right. `NOP` clears the
error; `STATUS` reports it with the geometry and counters.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` / `rst_n` | in | 1 | Clock and active-low reset |
| `s_axis_tvalid/tready/tdata/tlast` | — | 1/1/`ARRAY_N*8`/1 | Command stream |
| `m_axis_tvalid/tready/tdata/tlast` | — | 1/1/`ARRAY_N*8`/1 | Result stream |
| `irq` | out | 1 | Pulse when an output frame's last beat is taken |
| `error` | out | 1 | Sticky protocol error |
| `busy` | out | 1 | Parsing, computing, or results unread |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `ARRAY_N` | `int unsigned` | 16 | >= 8 | Array dimension; stream is `ARRAY_N*8` wide |
| `DATA_WIDTH` | `int unsigned` | 8 | 8 | Fixed: the header puts clamps on byte boundaries |
| `ACC_WIDTH` | `int unsigned` | 32 | >= 20 | Accumulator width |
| `MULT_WIDTH` | `int unsigned` | 24 | >= 2 | Requantisation multiplier width |
| `SHIFT_WIDTH` | `int unsigned` | 6 | >= 1 | Requantisation shift width |
| `ACC_DEPTH` | `int unsigned` | 256 | 2..65535 | Largest `COMPUTE` batch |
| `OUT_FIFO_DEPTH` | `int unsigned` | 64 | > `2*ARRAY_N+4` | Output buffer depth |

## Size

Structural counts at the default size: about **24400 flip-flops**, ~290 DSP
blocks and ~9 block RAMs — 256 DSPs in the array, two per requantiser, and a
256 x 512-bit accumulator buffer. The register counts follow from the
structure; the DSP and BRAM figures are what it implies on UltraScale+ and
should be confirmed against a real synthesis run.

## Driving it

A single-tile layer:

```
LOAD_WEIGHTS  16 beats     the weight tile, row 0 first
LOAD_PARAMS   16 beats     bias, multiplier and shift per output channel
COMPUTE       T beats      first = 1, last = 1     -> one T-beat result frame
```

A reduction four tiles deep sets `first` on the first `COMPUTE` and `last` on
the fourth; the interior ones emit nothing. Each tile's weight frame is parsed
while the previous tile's results are still draining.

The bare-metal Cortex-A53 driver and a worked convolution are in
[`sw/cnn_accel`](../../../sw/cnn_accel); the Zynq UltraScale+ integration is in
[`fpga/zynq_ultrascale`](../../../fpga/zynq_ultrascale).

## Verification

```bash
ctest --test-dir build -R 'cnn_accel'
```

- `cocotb/test_cnn_accel.py` — identity layer, single-tile and three-tile GEMMs
  against a model of the whole datapath, fused ReLU, per-channel parameters,
  interrupt and counters, twelve random layers, 30%-ready back-pressure, a
  measured-and-bounded throughput test, a full accumulator buffer, and five
  malformed frames each followed by a good job.
- `tb/tb_cnn_accel.sv` — portable self-checking smoke test at 8x8.

Full documentation: [`docs/index.rst`](docs/index.rst).
