# fir

Transposed-form FIR filter, one sample per cycle, with run-time loadable
coefficients and a full-precision output.

```
y[n] = sum over k of h[k] * x[n-k],   k = 0 .. TAPS-1
```

Every accepted sample is multiplied by all `TAPS` coefficients at once and the
products join partial sums that move one register towards the output per
sample. The longest path is one multiplier and one adder whatever `TAPS` is.
The output is exact: `DATA_WIDTH + COEF_WIDTH + $clog2(TAPS)` bits hold every
possible sum, so nothing saturates.

| | |
|---|---|
| **Category** | `dsp` |
| **Top module** | `fir` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Throughput** | one sample per cycle |
| **Latency** | 1 cycle |
| **Verified at** | `TAPS=8 DATA_WIDTH=12 COEF_WIDTH=10`; `TAPS=7` in the SV testbench |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `coef_wr_en`, `coef_addr`, `coef_data` | in | 1, `$clog2(TAPS)`, `COEF_WIDTH` | Write `h[coef_addr]`; addresses at or beyond `TAPS` are ignored |
| `s_valid` / `s_ready` | in / out | 1 | Input handshake |
| `s_data` | in | `DATA_WIDTH` | Signed sample |
| `m_valid` / `m_ready` | out / in | 1 | Output handshake |
| `m_data` | out | `DATA_WIDTH+COEF_WIDTH+$clog2(TAPS)` | Exact signed result |

A coefficient write affects products formed after it; outputs already in
progress keep their old products, so the new set is fully in effect `TAPS`
samples later. Load coefficients while the stream is idle to avoid the blend.

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `TAPS` | `int unsigned` | 16 | 2 to 256 | Number of coefficients |
| `DATA_WIDTH` | `int unsigned` | 16 | 2 to 32 | Signed sample width |
| `COEF_WIDTH` | `int unsigned` | 16 | 2 to 32 | Signed coefficient width |

## Quick start

```bash
ctest --test-dir build -R 'fir'
```

Documentation: [`docs/index.rst`](docs/index.rst).
