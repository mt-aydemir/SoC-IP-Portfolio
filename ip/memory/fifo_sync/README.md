# fifo_sync

Synchronous FIFO with ready/valid interfaces on both sides,
first-word-fall-through, and programmable almost-full and almost-empty flags.

| | |
|---|---|
| **Category** | `memory` |
| **Top module** | `fifo_sync` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | 1 cycle when empty (bypass), 3 through the RAM |
| **Throughput** | one word per cycle, both directions at once |
| **Depends on** | `ram_sdp` |
| **Licence** | Apache-2.0 |

## How it is built

Storage is a `ram_sdp` instance, so the FIFO costs one block RAM rather than
`DEPTH x DATA_WIDTH` flip-flops. That brings one problem: a synchronous RAM has
a cycle of read latency, while first-word-fall-through means the head word must
be visible *before* anyone asks for it.

The two are reconciled by a **two-entry output stage** that runs ahead of the
consumer, prefetching whenever it has room. Two entries rather than one because
a read issued this cycle delivers next cycle and must have somewhere to go on
arrival regardless of what the consumer does in between — one entry would mean
either stalling the prefetch whenever the output is occupied, halving
throughput, or dropping a word.

A **write bypass** sends an incoming word straight to the output stage when the
RAM is empty and no read is in flight, taking the empty-FIFO latency from three
cycles to one. It is suppressed whenever anything is ahead of it, so order is
always preserved.

Capacity is exactly `DEPTH` words counting both the RAM and the output stage,
so `level` reports what a consumer can actually still read.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Clock |
| `rst_n` | in | 1 | Active-low reset |
| `s_valid` | in | 1 | Write payload valid |
| `s_ready` | out | 1 | FIFO will accept a word |
| `s_data` | in | `DATA_WIDTH` | Write payload |
| `m_valid` | out | 1 | Read payload valid |
| `m_ready` | in | 1 | Consumer accepts a word |
| `m_data` | out | `DATA_WIDTH` | Read payload |
| `level` | out | `$clog2(DEPTH+1)` | Words currently held |
| `full` / `empty` | out | 1 | Occupancy flags |
| `almost_full` / `almost_empty` | out | 1 | Programmable threshold flags |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_WIDTH` | `int unsigned` | 32 | >= 1 | Payload width |
| `DEPTH` | `int unsigned` | 16 | >= 2 | Capacity in words; need not be a power of two |
| `ALMOST_FULL_LEVEL` | `int unsigned` | `DEPTH-1` | <= `DEPTH` | `almost_full` asserts at this level or above |
| `ALMOST_EMPTY_LEVEL` | `int unsigned` | 1 | — | `almost_empty` asserts at this level or below |

## Quick start

```systemverilog
fifo_sync #(
  .DATA_WIDTH (64),
  .DEPTH      (32)
) u_fifo (
  .clk (clk), .rst_n (rst_n),
  .s_valid (up_valid), .s_ready (up_ready), .s_data (up_data),
  .m_valid (dn_valid), .m_ready (dn_ready), .m_data (dn_data),
  .level (), .full (), .empty (),
  .almost_full (throttle), .almost_empty ()
);
```

## Verification

```bash
ctest --test-dir build -R 'fifo_sync'
```

- `cocotb/test_fifo_sync.py` — reset state, measured fall-through latency,
  filling to exactly `DEPTH`, draining in order, the almost flags at every
  level, 500 words of randomised traffic with back-pressure on both sides, 1000
  words at full rate, the FIFO held full then drained, and a mid-stream reset.
  Run at depths 16, 5 and 2.
- `tb/tb_fifo_sync.sv` — portable self-checking smoke test.

Full documentation: [`docs/index.rst`](docs/index.rst).
