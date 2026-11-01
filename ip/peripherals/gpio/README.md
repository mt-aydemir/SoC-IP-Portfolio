# gpio

General-purpose I/O port with per-pin direction, atomic set/clear,
synchronised inputs and edge interrupts.

Every input passes through a synchroniser before anything reads it, and the
pins are synchronised independently: `IN` is a set of independent samples,
not a coherent word.

| | |
|---|---|
| **Category** | `peripherals` |
| **Top module** | `gpio` |
| **Depends on** | `cdc_sync_2ff` |
| **Clock domains** | 1 (`clk`); `pin_in` asynchronous |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | writes on the next edge; `IN` lags the pad by `SYNC_STAGES` cycles |
| **Verified at** | `WIDTH=8 SYNC_STAGES=2` |
| **Licence** | Apache-2.0 |

## Register map

| addr | Name | Access | Description |
|---|---|---|---|
| 0 | `OUT` | rw | Output value of every pin |
| 1 | `DIR` | rw | 1 = output, 0 = input |
| 2 | `IN` | ro | Synchronised pin value |
| 3 | `OUT_SET` | wo | `OUT \|= wr_data` |
| 4 | `OUT_CLR` | wo | `OUT &= ~wr_data` |
| 5 | `RISE_EN` | rw | Interrupt on rising edge |
| 6 | `FALL_EN` | rw | Interrupt on falling edge |
| 7 | `STATUS` | rw1c | Latched edge events |

`rd_data` is combinational on `addr`. `irq` is high while any `STATUS` bit is
set. An edge in the same cycle as the clear of its bit keeps the bit set.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Rising-edge clock |
| `rst_n` | in | 1 | Active-low reset |
| `addr` | in | 3 | Register address |
| `wr_en` | in | 1 | Write strobe |
| `wr_data` | in | `WIDTH` | Write data |
| `rd_data` | out | `WIDTH` | Register at `addr` |
| `pin_in` | in | `WIDTH` | Pad inputs, asynchronous |
| `pin_out` | out | `WIDTH` | Pad output values (`OUT`, not masked by `DIR`) |
| `pin_oe` | out | `WIDTH` | Pad output enables (`DIR`) |
| `irq` | out | 1 | Level interrupt |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `WIDTH` | `int unsigned` | 8 | 1 to 32 | Number of pins |
| `SYNC_STAGES` | `int unsigned` | 2 | >= 2 | Input synchroniser depth |

## Quick start

```bash
ctest --test-dir build -R 'gpio'
```

Documentation: [`docs/index.rst`](docs/index.rst).
