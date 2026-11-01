# systolic_pe

Weight-stationary processing element for an int8 systolic matrix-multiply
array: one multiply-accumulate per cycle with a double-buffered weight
register.

| | |
|---|---|
| **Category** | `ml` |
| **Top module** | `systolic_pe` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | 1 cycle |
| **Throughput** | one multiply-accumulate per cycle |
| **Depends on** | — |
| **Licence** | Apache-2.0 |

## How it is built

The element holds one weight and sees one activation per cycle. It adds the
product to the partial sum arriving from the north and hands the total to the
south, while passing the activation on to the east. Every signal is a
register-to-register hop between adjacent cells, which is what lets an array of
these scale without the fanout of a broadcast bus.

The weight path is **two registers deep**. `w_shift` moves the load chain,
`w_commit` publishes the staged weight to the multiplier. That separation is
what allows the next weight tile to be pushed through the array while the
current one is still computing — without it, every tile change would cost a
bubble as long as the array is deep.

The chain runs **south to north**, which is the direction that lets a host push
weight rows in their natural order and have each land in the row that owns it.

There is **no clock enable**: an enable on every cell of a 256-element array is
a fanout problem, and it stops the multiply-accumulate being absorbed into a
DSP block. Idle cycles carry a zero activation, which contributes nothing.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Clock |
| `rst_n` | in | 1 | Active-low reset |
| `w_shift` | in | 1 | Advance the weight load chain |
| `w_commit` | in | 1 | Publish the staged weight; wins over `w_shift` |
| `w_in` / `w_out` | in / out | `DATA_WIDTH` | Weight chain, south to north |
| `a_in` / `a_out` | in / out | `DATA_WIDTH` | Activation, west to east |
| `psum_in` / `psum_out` | in / out | `ACC_WIDTH` | Partial sum, north to south |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_WIDTH` | `int unsigned` | 8 | 2 to 18 | Operand width, two's complement |
| `ACC_WIDTH` | `int unsigned` | 32 | >= `2*DATA_WIDTH` | Partial sum width |

## Quick start

```systemverilog
systolic_pe #(
  .DATA_WIDTH (8),
  .ACC_WIDTH  (32)
) u_pe (
  .clk (clk), .rst_n (rst_n),
  .w_shift (w_shift), .w_commit (w_commit),
  .w_in (w_from_below), .w_out (w_to_above),
  .a_in (a_from_west),  .a_out (a_to_east),
  .psum_in (psum_from_above), .psum_out (psum_to_below)
);
```

`w_commit` must not be asserted while activations from the previous tile are
still inside the array — those vectors would finish against a mixture of two
weight tiles. `systolic_array` drains before it commits.

## Verification

```bash
ctest --test-dir build -R 'systolic_pe'
```

- `cocotb/test_systolic_pe.py` — reset state, the one-cycle multiply-accumulate,
  the activation hand-off east, the weight shift chain, the double buffer, the
  signed extremes including `DATA_MIN * DATA_MIN`, 2000 randomised operand
  triples against a Python model, a sustained bubble-free stream, and a commit
  landing while data is in flight.
- `tb/tb_systolic_pe.sv` — portable self-checking smoke test.

Full documentation: [`docs/index.rst`](docs/index.rst).
