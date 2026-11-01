# iir

Second-order IIR section (biquad), direct form I, one sample per cycle, with
run-time coefficients, rounding and saturation.

```
y[n] = b0 x[n] + b1 x[n-1] + b2 x[n-2] - a1 y[n-1] - a2 y[n-2]
```

Higher-order filters are cascades of these sections, the form every IIR design
tool produces and the one least sensitive to coefficient quantisation.

| | |
|---|---|
| **Category** | `dsp` |
| **Top module** | `iir` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Throughput** | one sample per cycle |
| **Latency** | 1 cycle |
| **Verified at** | `DATA_WIDTH=12 COEF_WIDTH=12 COEF_FRAC=10`; `COEF_FRAC=14` and `0` in the SV testbench |
| **Licence** | Apache-2.0 |

## Fixed point

Coefficients are `COEF_WIDTH`-bit signed with `COEF_FRAC` fractional bits;
with the defaults they span [-2, 2), which holds every stable `a1`. The five
products are summed exactly, rounded half up at `COEF_FRAC`, and saturated to
`DATA_WIDTH`. The saturated value is what is fed back, so an overflow clips
instead of wrapping into an oscillation; `m_saturated` flags every clipped
output.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `coef_wr_en`, `coef_addr`, `coef_data` | in | 1, 3, `COEF_WIDTH` | 0 `b0`, 1 `b1`, 2 `b2`, 3 `a1`, 4 `a2`; others ignored |
| `s_valid` / `s_ready` | in / out | 1 | Input handshake |
| `s_data` | in | `DATA_WIDTH` | Signed sample |
| `m_valid` / `m_ready` | out / in | 1 | Output handshake |
| `m_data`, `m_saturated` | out | `DATA_WIDTH`, 1 | Output and its clip flag |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_WIDTH` | `int unsigned` | 16 | 2 to 32 | Signed sample width |
| `COEF_WIDTH` | `int unsigned` | 18 | 2 to 32 | Signed coefficient width |
| `COEF_FRAC` | `int unsigned` | 16 | 0 to `COEF_WIDTH-1` | Coefficient fractional bits |

## Quick start

```bash
ctest --test-dir build -R 'iir'
```

Documentation: [`docs/index.rst`](docs/index.rst).
