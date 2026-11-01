# cic

Cascaded integrator-comb (Hogenauer) decimator with a run-time decimation rate
and a full-precision output.

A CIC filter decimates by `R` with no multiplier: `STAGES` integrators at the
input rate, a rate change, and `STAGES` combs at the output rate. Its response
is `STAGES` cascaded moving sums of length `R*M`, which makes it the usual first
stage of a digital down-converter.

| | |
|---|---|
| **Category** | `dsp` |
| **Top module** | `cic` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Gain** | `(rate * DIFF_DELAY) ** STAGES` |
| **Output width** | `DATA_WIDTH + STAGES * $clog2(MAX_RATE * DIFF_DELAY)` |
| **Verified at** | `STAGES=4 MAX_RATE=16 DIFF_DELAY=1 DATA_WIDTH=12`; `M=2` in the SV testbench |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `rate` | in | `$clog2(MAX_RATE+1)` | Decimation rate, 1 to `MAX_RATE`; change between bursts |
| `s_valid` / `s_ready` | in / out | 1 | Input handshake |
| `s_data` | in | `DATA_WIDTH` | Signed sample |
| `m_valid` / `m_ready` | out / in | 1 | Output handshake, one output per `rate` inputs |
| `m_data` | out | see above | Exact signed output |

The integrators overflow by design and wrap: every register is the full output
width, and two's-complement wrap-around is undone exactly by the combs. Only a
sample that would produce an output while the output register is still full is
refused; all others are taken at one per cycle.

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `STAGES` | `int unsigned` | 4 | 1 to 8 | Integrator/comb pairs, N |
| `MAX_RATE` | `int unsigned` | 64 | 2 to 65536 | Largest decimation rate |
| `DIFF_DELAY` | `int unsigned` | 1 | 1, 2 | Comb differential delay, M |
| `DATA_WIDTH` | `int unsigned` | 16 | 2 to 32 | Signed input width |

## Quick start

```bash
ctest --test-dir build -R 'cic'
```

Documentation: [`docs/index.rst`](docs/index.rst).
