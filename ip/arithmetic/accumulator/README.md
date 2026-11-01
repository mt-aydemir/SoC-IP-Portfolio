# accumulator

Parameterised accumulator with load, clear, enable and optional saturation.

The accumulator is **wider than its input**, which is the whole point of
having one as an IP rather than writing `sum <= sum + x` inline. Adding *N*
values of `DATA_WIDTH` bits needs `DATA_WIDTH + $clog2(N)` bits to hold every
possible result, and getting that width wrong is the most common defect in
accumulate loops: the sum is correct for the test vectors and wraps on real
data.

| | |
|---|---|
| **Category** | `arithmetic` |
| **Top module** | `accumulator` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | 1 cycle — `acc_out` reflects inputs applied on the previous edge |
| **Verified at** | `DATA_WIDTH=16 ACC_WIDTH=32 SIGNED=1 SATURATE=1` |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Rising-edge clock |
| `rst_n` | in | 1 | Active-low reset |
| `clear` | in | 1 | Zero the total — highest priority |
| `load` | in | 1 | Replace the total with `load_data` |
| `enable` | in | 1 | Add `data_in` to the total this cycle |
| `data_in` | in | `DATA_WIDTH` | Value added when `enable` is asserted |
| `load_data` | in | `ACC_WIDTH` | New total when `load` is asserted |
| `acc_out` | out | `ACC_WIDTH` | The running total |
| `overflow` | out | 1 | The addition performed on this edge was not representable |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_WIDTH` | `int unsigned` | 16 | >= 1 | Width of the value added each cycle |
| `ACC_WIDTH` | `int unsigned` | 32 | >= `DATA_WIDTH`, >= 2 | Width of the accumulator |
| `SIGNED` | `int unsigned` | 1 | 0 or 1 | Interpret both as two's complement |
| `SATURATE` | `int unsigned` | 0 | 0 or 1 | Clamp instead of wrapping |

## Control priority

**`clear` beats `load` beats `enable`.** Clear is the recovery path and must
always work, which is why nothing can mask it. Asserting several controls at
once is legal, and the priority rule is what makes the result well defined.

## Growth

`ACC_WIDTH` is the caller's decision, because only the caller knows how many
values will be accumulated between clears. The block does not guess. What it
does do is **report overflow**, so a wrong choice is visible rather than
silent.

## Saturation

With `SATURATE` set the accumulator clamps at the limit instead of wrapping.
Signal processing wants this: an accumulator that wraps turns a large sum into
a large negative one, which in a filter is an audible click, while one that
clamps merely distorts. A statistics counter wants the opposite, so the
default is off.

Saturation is sticky in effect but **not in state**. Once clamped the total
stays at the limit only while inputs keep pushing it there, and a subsequent
input of the opposite sign moves it back. That is deliberate — a latching
saturation flag belongs to the consumer, and `overflow` is provided for
exactly that purpose.

For the same reason `overflow` describes *the addition performed on this
edge*, so an idle cycle clears it even though the total is unchanged.

## Quick start

```systemverilog
accumulator #(
  .DATA_WIDTH (16),
  .ACC_WIDTH  (40),     // 16-bit products, up to 128 of them: 32 + 7
  .SIGNED     (1),
  .SATURATE   (1)
) u_acc (
  .clk       (clk),
  .rst_n     (rst_n),
  .clear     (frame_start),
  .load      (1'b0),
  .enable    (sample_valid),
  .data_in   (sample),
  .load_data ('0),
  .acc_out   (total),
  .overflow  (total_clipped)
);
```

## Verification

```bash
ctest --test-dir build -R 'accumulator'
```

- `cocotb/test_accumulator.py` — a cycle-accurate Python replica of the
  specification, stepped once per clock edge and compared after it, so
  anything the design does a cycle early or late fails. Covers the reset
  state, accumulation, hold, load, clear, the full control priority matrix,
  both saturation limits, random control every cycle, totals pushed across a
  limit deliberately, a long accumulation beyond the data width, the
  non-sticky nature of saturation, and a mid-stream reset.
- `tb/tb_accumulator.sv` — portable self-checking smoke test whose reference
  total is kept in a 64-bit integer, so the model decides the answer in
  arithmetic that cannot itself overflow.

## Files

```
rtl/accumulator.sv          synthesisable RTL
tb/tb_accumulator.sv        SystemVerilog testbench
cocotb/test_accumulator.py  cocotb regression
docs/index.rst              full documentation
scripts/accumulator.sdc     timing constraints
```

Full documentation: [`docs/index.rst`](docs/index.rst).
