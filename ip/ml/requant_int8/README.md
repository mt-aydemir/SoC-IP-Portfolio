# requant_int8

Quantised-neural-network requantisation: a wide integer accumulator back down
to an int8 activation, with a per-channel bias, a fixed-point scale, round to
nearest and a saturating clamp.

| | |
|---|---|
| **Category** | `ml` |
| **Top module** | `requant_int8` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | 3 cycles |
| **Throughput** | one result per cycle |
| **Depends on** | — |
| **Licence** | Apache-2.0 |

## What it computes

```
out = clamp( round( (acc + bias) * mult / 2**shift ) + out_zero_point,
             out_min, out_max )
```

A quantised convolution accumulates int8 products into a 32-bit total in the
scale `S_a * S_w`. The next layer wants its input in `S_out`. `mult` and
`shift` are the fixed-point representation of `(S_a * S_w) / S_out`.

`bias`, `mult` and `shift` are **ports, not parameters**: every output channel
of a layer has its own, and per-channel quantisation is the normal case, not an
optimisation.

**Rounding** is to nearest, ties away from zero, applied once to the full-width
product — the same rule as gemmlowp's `RoundingDivideByPOT`. Adding `half`
before an arithmetic shift rounds half up; adding `half - 1` instead when the
value is negative moves the ties away from zero. A shift of zero must add
nothing, or every negative result is dragged down by one.

**Zero points**: only the output zero point is here. The input zero point is
folded into `bias` by the host through
`sum w*(a - z) = sum w*a - z*sum w`, whose correction term depends only on the
weights. That is what lets the array in front of this block be purely signed
int8 with no per-multiply subtraction.

**Fused ReLU** is not a mode — it is `out_min` raised to the output zero point,
which is exactly how a quantised graph represents it.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` / `rst_n` | in | 1 | Clock and active-low reset |
| `in_valid` | in | 1 | This cycle's operands are a real job; never stalls |
| `acc` | in | `ACC_WIDTH` | Accumulator, signed |
| `bias` | in | `ACC_WIDTH` | Per-channel bias, signed, zero-point corrected |
| `mult` | in | `MULT_WIDTH` | Fixed-point scale numerator, unsigned |
| `shift` | in | `SHIFT_WIDTH` | Right shift after the multiply |
| `out_zero_point` | in | `OUT_WIDTH` | Added after the shift, signed |
| `out_min` / `out_max` | in | `OUT_WIDTH` | Inclusive clamp window |
| `out_valid` | out | 1 | `in_valid` delayed by the latency |
| `out_data` | out | `OUT_WIDTH` | Requantised result, signed |
| `saturated` | out | 1 | This result was clipped |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `ACC_WIDTH` | `int unsigned` | 32 | >= 4 | Accumulator and bias width |
| `MULT_WIDTH` | `int unsigned` | 24 | >= 2 | Fixed-point multiplier width, unsigned |
| `SHIFT_WIDTH` | `int unsigned` | 6 | >= 1 | Shift amount width |
| `OUT_WIDTH` | `int unsigned` | 8 | 2 to `ACC_WIDTH` | Output width |

## Quick start

```systemverilog
requant_int8 #(
  .ACC_WIDTH (32), .MULT_WIDTH (24), .SHIFT_WIDTH (6), .OUT_WIDTH (8)
) u_requant (
  .clk (clk), .rst_n (rst_n),
  .in_valid (col_valid), .acc (col_acc),
  .bias (bias_q), .mult (mult_q), .shift (shift_q),
  .out_zero_point (zp_q), .out_min (min_q), .out_max (max_q),
  .out_valid (res_valid), .out_data (res_data), .saturated (res_clipped)
);
```

## Verification

```bash
ctest --test-dir build -R 'requant_int8'
```

Every check is an equality — the block's value is that it is bit-exact, so the
Python model is the specification rather than an approximation.

- `cocotb/test_requant_int8.py` — latency, exact power-of-two scales, the
  rounding rule at every tie of both signs, shift of zero, both clamp edges,
  fused ReLU through `out_min`, 6000 randomised parameter sets, full-rate
  results with the parameters changing on every beat, and gapped input.
- `tb/tb_requant_int8.sv` — portable self-checking smoke test with a 64-bit
  reference model.

Full documentation: [`docs/index.rst`](docs/index.rst).
