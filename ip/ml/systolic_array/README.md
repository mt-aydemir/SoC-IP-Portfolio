# systolic_array

`ROWS` by `COLS` weight-stationary systolic array of int8 multiply-accumulate
elements, with the input skew and output deskew that turn it into a plain
vector-in, vector-out matrix multiplier.

| | |
|---|---|
| **Category** | `ml` |
| **Top module** | `systolic_array` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | `ROWS + COLS - 1` cycles |
| **Throughput** | one activation vector per cycle |
| **Depends on** | `systolic_pe` |
| **Licence** | Apache-2.0 |

## What it computes

With a weight tile `W` loaded, presenting an activation vector `a` gives

```
res[m] = sum over k of  W[k][m] * a[k]
```

`ROWS + COLS - 1` cycles later. One vector per cycle, sustained — a 16x16 array
retires 256 multiply-accumulates every cycle while moving 128 bits of
activation in and 512 bits of accumulator out.

## How it is built

Inside the array an activation walks east one element per cycle and a partial
sum walks south one element per cycle. For the two to meet at the element
holding `W[k][m]`, row `k`'s activation must be launched `k` cycles late — that
is the **input skew**. The columns therefore finish staggered too, and the
**output deskew** delays column `m` by `COLS-1-m` to bring them back into step.
The result is a flat fixed latency instead of an interface that exposes
wavefronts.

The deskew registers are accumulator width, which is the one place this
partitioning costs area — requantising before the deskew would make them 8 bits
instead of 32. That is deliberately not done here: it would put a quantisation
policy inside a block whose job is arithmetic, and it would stop the array being
usable for reductions deeper than `ROWS`.

**No back-pressure.** `a_valid` travels with the data, idle cycles inject zeros
which contribute nothing, and a consumer that might stall must simply not
present a vector. `cnn_accel` admits work only when there is already room for
the result.

**Weights are double buffered.** Rows enter at the south edge in natural order
and shift north; `w_commit` publishes the whole tile at once. The next tile can
be pushed through while the current one computes, so a layer made of many tiles
pays no idle cycles for weight loads. A commit while `busy` is high would leave
in-flight vectors accumulating against a mixture of two tiles — an assertion
catches it.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` / `rst_n` | in | 1 | Clock and active-low reset |
| `w_valid` | in | 1 | This cycle's `w_row` is a weight row |
| `w_row` | in | `COLS*DATA_WIDTH` | One weight row, column 0 in the low bits |
| `w_commit` | in | 1 | Publish the staged tile; illegal while `busy` |
| `a_valid` | in | 1 | This cycle's `a_vector` is real work |
| `a_vector` | in | `ROWS*DATA_WIDTH` | Activation vector, row 0 in the low bits |
| `res_valid` | out | 1 | `a_valid` delayed by the latency |
| `res_vector` | out | `COLS*ACC_WIDTH` | Result vector, column 0 in the low bits |
| `busy` | out | 1 | An admitted vector is still inside the pipeline |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `ROWS` | `int unsigned` | 16 | >= 2 | Reduction depth; activations per vector |
| `COLS` | `int unsigned` | 16 | >= 2 | Output channels; results per vector |
| `DATA_WIDTH` | `int unsigned` | 8 | 2 to 18 | Operand width |
| `ACC_WIDTH` | `int unsigned` | 32 | >= `2*DATA_WIDTH + $clog2(ROWS)` | Accumulator width |

## Size

Fixed by the structure, so it can be stated before synthesis. At 16x16, int8,
32-bit accumulator: 14336 flip-flops in the elements, 960 in the input skew,
3840 in the output deskew, 31 in the valid delay line — **19167 total**, plus
256 DSP blocks on an FPGA target. The critical path is one multiply plus one
add regardless of the array size.

## Quick start

```systemverilog
systolic_array #(
  .ROWS (16), .COLS (16), .DATA_WIDTH (8), .ACC_WIDTH (32)
) u_array (
  .clk (clk), .rst_n (rst_n),
  .w_valid (weight_beat), .w_row (weight_row), .w_commit (publish_tile),
  .a_valid (admit), .a_vector (activation_vector),
  .res_valid (result_beat), .res_vector (result_vector),
  .busy (array_busy)
);

assign admit        = activation_available && output_credit_available;
assign publish_tile = tile_staged && !array_busy;
```

## Verification

```bash
ctest --test-dir build -R 'systolic_array'
```

- `cocotb/test_systolic_array.py` — latency, an identity tile (the test that
  makes a skew off by one visible directly), a hand-computed vector, the signed
  extremes, `busy` checked cycle by cycle, 20 random tiles against a Python
  matrix multiply, a batch with 30% idle cycles, 500 vectors at full rate, a
  tile loaded *while* a batch computes, and three consecutive tiles.
- `tb/tb_systolic_array.sv` — portable self-checking smoke test at 8x8.

Full documentation: [`docs/index.rst`](docs/index.rst).
