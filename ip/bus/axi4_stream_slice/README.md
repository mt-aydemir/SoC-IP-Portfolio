# axi4_stream_slice

AMBA AXI4-Stream register slice that breaks the forward path, the backward
(`TREADY`) path, or both, without losing throughput.

A long stream fails timing on one of two paths: `TVALID` and the payload going
forward, or `TREADY` coming back. The slice cuts one or both with registers.
Every beat is delivered exactly once, in order, with every sideband intact;
only its timing changes.

| | |
|---|---|
| **Category** | `bus` |
| **Top module** | `axi4_stream_slice` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Verified at** | `MODE=3 DATA_WIDTH=32`, 5.0 ns; all five modes in both suites |
| **Licence** | Apache-2.0 |

## Modes

| `MODE` | Name | Cuts | Throughput | Latency | Registers |
|---|---|---|---|---|---|
| 0 | `BYPASS` | nothing | full | 0 | none |
| 1 | `FORWARD` | `TVALID`, payload | full | 1 | 1 beat |
| 2 | `REVERSE` | `TREADY` | full | 0 | 1 beat (skid) |
| 3 | `FULL` | both | full | 1 | 2 beats |
| 4 | `LIGHT` | both | half | 1 | 1 beat |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `s_axis_tvalid` / `s_axis_tready` | in / out | 1 | Input handshake |
| `m_axis_tvalid` / `m_axis_tready` | out / in | 1 | Output handshake |
| `*_tdata` | | `DATA_WIDTH` | Data |
| `*_tstrb`, `*_tkeep` | | `DATA_WIDTH/8` | Byte qualifiers |
| `*_tlast` | | 1 | Packet boundary |
| `*_tid`, `*_tdest`, `*_tuser` | | `ID_WIDTH`, `DEST_WIDTH`, `USER_WIDTH` | Routing and user sidebands |

Unused sidebands: tie the input to a constant and leave the output open;
synthesis removes the constant register.

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `MODE` | `int unsigned` | 3 | 0 to 4 | Which paths are cut, above |
| `DATA_WIDTH` | `int unsigned` | 32 | multiple of 8 | `TDATA` width |
| `ID_WIDTH` | `int unsigned` | 1 | >= 1 | `TID` width |
| `DEST_WIDTH` | `int unsigned` | 1 | >= 1 | `TDEST` width |
| `USER_WIDTH` | `int unsigned` | 1 | >= 1 | `TUSER` width |

## Quick start

```bash
ctest --test-dir build -R 'axi4_stream_slice'
```

Documentation: [`docs/index.rst`](docs/index.rst).
