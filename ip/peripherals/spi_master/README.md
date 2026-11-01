# spi_master

SPI master with run-time mode and bit order, a programmable SCLK rate and
multi-word chip-select framing.

Every word is exactly `2 * DATA_WIDTH` SCLK edges, half a period apart, with
half a period of chip-select setup and hold. The implementation this replaces
produced one edge too few, which its own receive path hid and a real slave
did not.

| | |
|---|---|
| **Category** | `peripherals` |
| **Top module** | `spi_master` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Modes** | all four, plus bit order, selected at run time |
| **Word time** | `(2 * DATA_WIDTH + 2) * clk_div` cycles |
| **Verified at** | `DATA_WIDTH=8` and `12` |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | Clock, active-low reset |
| `cpol`, `cpha`, `lsb_first` | in | 1 | Mode and bit order; change only while idle |
| `clk_div` | in | `DIV_WIDTH` | SCLK half period in clocks, >= 1 |
| `s_valid` / `s_ready` / `s_data` / `s_last` | in / out / in / in | | Words to send; `s_last` ends the frame |
| `m_valid` / `m_data` | out | | Received word, one pulse per word |
| `busy` | out | 1 | Frame in progress |
| `sclk`, `mosi`, `cs_n` | out | 1 | Bus outputs, registered |
| `miso` | in | 1 | Bus input |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_WIDTH` | `int unsigned` | 8 | >= 2 | Bits per word |
| `DIV_WIDTH` | `int unsigned` | 8 | >= 1 | Width of `clk_div` |

## Framing

A word without `s_last` keeps `cs_n` low and SCLK idle until the next word,
however long the host takes, so command, address and data phases form one
frame. After `s_last`, `cs_n` rises for at least half a period.

## Quick start

```bash
ctest --test-dir build -R 'spi_master'
```

Documentation: [`docs/index.rst`](docs/index.rst).
