# mac_array

`LANES`-wide multiply-accumulate array: a pipelined dot-product engine that
multiplies `LANES` operand pairs per cycle, sums them through a registered
adder tree, and accumulates the sums over the beats of a vector.

```
m_data = sum over beats, sum over lanes i of  a[i] * b[i]     (mod 2**ACC_WIDTH)
```

A vector is any number of beats, ended by `s_last`. Each operand can be
signed or unsigned, so uint8 activations against int8 weights are
multiplied exactly. Where `systolic_array` holds a weight tile in place and
computes a tile of dot products at once, this block takes both operands as
streams, one dot product at a time: the shape for layers with no weight
reuse, such as fully connected layers at batch size one or depthwise
convolutions.

The pipeline never stalls. Results go into a small output FIFO, and
`s_ready` comes from a registered count of the results not yet taken, so
there is no combinational path from `m_ready` to `s_ready` and the sink's
ready does not fan out to the pipeline.

| | |
|---|---|
| **Category** | `ml` |
| **Top module** | `mac_array` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Throughput** | one beat of `LANES` pairs per cycle, even when every beat ends a vector |
| **Latency** | `$clog2(LANES) + 2` cycles from the last beat to the result |
| **Verified at** | `LANES=16 DATA_WIDTH=8 ACC_WIDTH=32`, unsigned a, signed b; six other sets in cocotb; `LANES=5` in the SV testbench |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `s_valid` / `s_ready` | in / out | 1 | Beat handshake |
| `s_a`, `s_b` | in | `LANES*DATA_WIDTH` | Operands; lane `i` is bits `[i*DATA_WIDTH +: DATA_WIDTH]` |
| `s_last` | in | 1 | Last beat of the vector |
| `m_valid` / `m_ready` | out / in | 1 | Result handshake |
| `m_data` | out | `ACC_WIDTH` | The dot product, two's complement, modulo `2**ACC_WIDTH` |

A vector whose length is not a multiple of `LANES` is padded with zero
operands in its last beat.

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `LANES` | `int unsigned` | 16 | 1 to 64 | Operand pairs per beat |
| `DATA_WIDTH` | `int unsigned` | 8 | 2 to 16 | Operand width |
| `ACC_WIDTH` | `int unsigned` | 32 | `2*DATA_WIDTH+1+$clog2(LANES)` to 64 | Accumulator width |
| `A_SIGNED` | `int unsigned` | 1 | 0, 1 | `s_a` lanes are two's complement (1) or unsigned (0) |
| `B_SIGNED` | `int unsigned` | 1 | 0, 1 | `s_b` lanes likewise |

## Quick start

```bash
ctest --test-dir build -R 'mac_array'
```

Documentation: [`docs/index.rst`](docs/index.rst).
