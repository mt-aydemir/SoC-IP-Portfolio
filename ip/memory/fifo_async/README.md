# fifo_async

Asynchronous FIFO. Moves a data stream between two clock domains of arbitrary,
unrelated frequencies.

This is the block for continuous traffic across a clock boundary.
`cdc_handshake` pays a full round trip per word and is right for occasional
transfers; this one sustains one word per cycle in each domain.

| | |
|---|---|
| **Category** | `memory` |
| **Top module** | `fifo_async` |
| **Clock domains** | 2 (`wr_clk`, `rd_clk`), unrelated |
| **Reset** | `wr_rst_n` / `rd_rst_n`, active low, one per domain |
| **Latency** | `SYNC_STAGES + 2` read cycles |
| **Throughput** | one word per clock in each domain |
| **Depends on** | `ram_sdp`, `cdc_sync_2ff` |
| **Licence** | Apache-2.0 |

## How the pointers cross

The only things that cross the boundary are the two pointers, and they cross
Gray coded. A binary counter stepping from `0111` to `1000` changes every bit
at once, so a synchroniser sampling it mid-transition can produce any of the
sixteen values — including ones the counter never held. Gray code changes
exactly one bit per increment, so a sample taken during a transition yields
either the old value or the new one. Never anything else.

That property makes the comparison safe rather than merely usually correct. A
stale pointer makes the FIFO look emptier than it is on the write side and
fuller than it is on the read side — conservative in both directions, which is
the only acceptable direction to be wrong in.

The pointers carry one bit more than the address. That guard bit distinguishes
full from empty: both have equal address bits and differ only in whether the
pointers have wrapped a different number of times.

**`DEPTH` must be a power of two.** Gray coding relies on the counter wrapping
exactly at the top of its range; a counter that wraps early produces adjacent
codes differing in more than one bit and the guarantee collapses. This is
checked at elaboration.

## Capacity

Storage is `ram_sdp`, so a read takes a cycle, and first-word-fall-through
needs the head word visible before it is asked for. The read side therefore
runs a two-entry show-ahead stage, exactly as `fifo_sync` does. Total capacity
is `DEPTH + 2`; `wr_full` refers to the RAM, which is what the writer needs to
know.

## Interface

| Signal | Dir | Domain | Description |
|---|---|---|---|
| `wr_clk` / `wr_rst_n` | in | write | Write clock and reset |
| `s_valid` / `s_ready` / `s_data` | — | write | Write-side stream |
| `wr_level` / `wr_full` / `wr_almost_full` | out | write | Write-side status |
| `rd_clk` / `rd_rst_n` | in | read | Read clock and reset |
| `m_valid` / `m_ready` / `m_data` | — | read | Read-side stream |
| `rd_level` / `rd_empty` / `rd_almost_empty` | out | read | Read-side status |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_WIDTH` | `int unsigned` | 32 | >= 1 | Payload width |
| `DEPTH` | `int unsigned` | 16 | power of two, >= 4 | RAM depth in words |
| `SYNC_STAGES` | `int unsigned` | 2 | >= 2 | Synchroniser depth for both crossings |
| `ALMOST_FULL_LEVEL` | `int unsigned` | `DEPTH-2` | — | Write-side threshold |
| `ALMOST_EMPTY_LEVEL` | `int unsigned` | 1 | — | Read-side threshold |

## Constraints

[`scripts/fifo_async.sdc`](scripts/fifo_async.sdc) is **load bearing**, unlike
most of the memory SDC fragments. Without it the pointer crossings are either
left unanalysed by accident or, worse, analysed as if the clocks were related.

## Verification

```bash
ctest --test-dir build -R 'fifo_async'
```

- `cocotb/test_fifo_async.py` — reset state, a single word, filling to
  capacity, draining in order, randomised streams at three clock ratios,
  sustained full-rate traffic in each direction, twenty full pointer wraps, and
  recovery after reset. Run at depths 16 and 4.
- `tb/tb_fifo_async.sv` — portable smoke test at a 10 ns / 23 ns clock ratio.

Full documentation: [`docs/index.rst`](docs/index.rst).
