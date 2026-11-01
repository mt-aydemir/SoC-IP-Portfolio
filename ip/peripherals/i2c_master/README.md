# i2c_master

I2C bus master driven by byte-level commands, with clock stretching and
multi-master arbitration.

The host sequences START, WRITE, READ and STOP commands and gets one response
per command, so register pointers, repeated starts and 10-bit addresses need
no support in the block.

| | |
|---|---|
| **Category** | `peripherals` |
| **Top module** | `i2c_master` |
| **Depends on** | `cdc_sync_2ff` |
| **Clock domains** | 1 (`clk`); `scl_i`, `sda_i` asynchronous |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **SCL period** | `4 * clk_div` cycles, longer when stretched |
| **Verified at** | `DIV_WIDTH=16 SYNC_STAGES=2` |
| **Licence** | Apache-2.0 |

## Commands

| `s_cmd` | Command | Response |
|---|---|---|
| 0 | START / repeated START | — |
| 1 | STOP | — |
| 2 | WRITE `s_data` | `m_nack` = slave acknowledge |
| 3 | READ, then send `s_nack` | `m_data` = byte read |

Every response also carries `m_arb_lost`.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | Clock, active-low reset |
| `clk_div` | in | `DIV_WIDTH` | Quarter SCL period; `2 * clk_div >= SYNC_STAGES + 1` |
| `s_valid` / `s_ready` | in / out | 1 | Command handshake |
| `s_cmd`, `s_data`, `s_nack` | in | 2, 8, 1 | Command fields |
| `m_valid` | out | 1 | One pulse per command |
| `m_data`, `m_nack`, `m_arb_lost` | out | 8, 1, 1 | Response fields |
| `busy` | out | 1 | Command in progress |
| `scl_i`, `sda_i` | in | 1 | Line levels |
| `scl_oe`, `sda_oe` | out | 1 | Pull line low |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DIV_WIDTH` | `int unsigned` | 16 | >= 2 | Width of `clk_div` |
| `SYNC_STAGES` | `int unsigned` | 2 | >= 2 | Line synchroniser depth |

## Quick start

```bash
ctest --test-dir build -R 'i2c_master'
```

Documentation: [`docs/index.rst`](docs/index.rst).
