# lfsr_rng

Maximal-length LFSR as a pseudo-random bit source: `STEPS` fresh bits per
draw, one draw per cycle, a run-time seed and a stream output.

```
b[t] = XOR over k in TAPS(WIDTH) of b[t-k]        period 2**WIDTH - 1
```

The feedback taps come from a table of primitive polynomials (Xilinx
XAPP052) for every width from 2 to 64, so the register visits every non-zero
state. A draw advances the register `STEPS` times in one cycle, and
consecutive draws are consecutive, non-overlapping pieces of the one
sequence.

**Not a cryptographic generator.** An LFSR is linear: `2*WIDTH` output bits
determine the whole sequence. Use it for test patterns, scramblers, dither,
BIST and randomised arbitration, not for keys, nonces or masks.

| | |
|---|---|
| **Category** | `crypto` |
| **Top module** | `lfsr_rng` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Throughput** | one draw of `STEPS` bits per cycle |
| **Latency** | 1 cycle from `seed_load` to the first draw |
| **Verified at** | `WIDTH=32 STEPS=8`; five other sets in cocotb; every width 2 to 16 exhaustively in the SV testbench |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `seed_load`, `seed` | in | 1, `WIDTH` | Restart the sequence from `seed`; zero is replaced by 1 |
| `m_valid` / `m_ready` | out / in | 1 | Draw handshake; `m_valid` is high from the first cycle after reset |
| `m_data` | out | `STEPS` | The bits just generated, the newest in bit 0 |

A seed load wins over `m_ready`: a draw taken on the same edge is the last of
the old sequence, and the next one is the first from the new seed.

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `WIDTH` | `int unsigned` | 32 | 2 to 64 | State width; period `2**WIDTH - 1` |
| `STEPS` | `int unsigned` | 8 | 1 to `WIDTH` | Bits per draw |
| `SEED` | `logic [63:0]` | 1 | any | Reset state (low `WIDTH` bits; zero means 1) |

## Quick start

```bash
ctest --test-dir build -R 'lfsr_rng'
```

Documentation: [`docs/index.rst`](docs/index.rst).
