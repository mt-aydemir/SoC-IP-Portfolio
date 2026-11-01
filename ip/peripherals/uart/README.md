# uart

Full-duplex asynchronous serial transmitter and receiver with a run-time bit
period, optional parity and error reporting.

The bit period is an input, not a parameter derived from a clock frequency:
one netlist serves every baud rate, and the rounding of `CLK_HZ / BAUD` stays
with the integrator, who knows both numbers.

| | |
|---|---|
| **Category** | `peripherals` |
| **Top module** | `uart` |
| **Depends on** | `cdc_sync_2ff` |
| **Clock domains** | 1 (`clk`); `rxd` asynchronous |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Frame** | start, `DATA_BITS` LSB first, optional parity, `STOP_BITS` |
| **Verified at** | `DATA_BITS=8 PARITY=1 STOP_BITS=1` and `7 / odd / 2` |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Rising-edge clock |
| `rst_n` | in | 1 | Active-low reset |
| `clks_per_bit` | in | `DIV_WIDTH` | Bit period in clocks, >= 4 |
| `s_valid` / `s_ready` / `s_data` | in / out / in | | Transmit stream |
| `txd` | out | 1 | Serial out, idles high |
| `m_valid` / `m_ready` / `m_data` | out / in / out | | Receive stream |
| `m_parity_err` / `m_frame_err` | out | 1 | Errors of the character on `m_data` |
| `rx_overrun` | out | 1 | Pulse: a character was dropped |
| `rxd` | in | 1 | Serial in, asynchronous |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_BITS` | `int unsigned` | 8 | 5 to 9 | Data bits per character |
| `PARITY` | `int unsigned` | 0 | 0 / 1 / 2 | None / even / odd |
| `STOP_BITS` | `int unsigned` | 1 | 1 or 2 | Stop bits sent (one checked) |
| `DIV_WIDTH` | `int unsigned` | 16 | >= 3 | Width of `clks_per_bit` |
| `SYNC_STAGES` | `int unsigned` | 2 | >= 2 | `rxd` synchroniser depth |

## Receiver behaviour

- Start bit re-checked half a bit after the falling edge: glitches shorter
  than that are ignored.
- Bits sampled at their centre; about 4 % rate mismatch tolerated at
  `clks_per_bit = 16` (3 % verified).
- Framing error: delivered and flagged, then the receiver waits for the line
  to go high, so a break is one character, not a stream.
- Overrun: the held character is kept, the new one dropped, `rx_overrun`
  pulses.

## Quick start

```bash
ctest --test-dir build -R 'uart'
```

Documentation: [`docs/index.rst`](docs/index.rst).
