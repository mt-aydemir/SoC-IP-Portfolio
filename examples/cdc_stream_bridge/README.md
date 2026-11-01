# cdc_stream_bridge — a stream between unrelated clocks

An integration example: a ready/valid stream carried from one clock domain to
another, from a single raw asynchronous reset, built from
[`cdc_reset_sync`](../../ip/cdc/reset_sync) and
[`fifo_async`](../../ip/memory/fifo_async).

```
                     +----------------+
  arst_n --+-------->| cdc_reset_sync |--> src_rst_n --+
           |         |   (src_clk)    |                |
           |         +----------------+                v
           |                                  +------------------+
  s_valid/s_ready/s_data  (src_clk) =========>|    fifo_async    |=========> m_valid/m_ready/m_data (dst_clk)
           |                                  |  Gray pointers   |
           |         +----------------+       +------------------+
           +-------->| cdc_reset_sync |--> dst_rst_n --^
                     |   (dst_clk)    |
                     +----------------+
```

Clock domain crossing is the most common source of bugs that simulation does
not catch, and they are almost never inside the synchroniser — they are in how
it is wired. This is the wiring done right.

## What it gets right

| Rule | Why |
|---|---|
| **One raw reset, synchronised into each domain separately** | Each domain sees a reset that asserts immediately and releases on its own clock. Using one domain's synchronised reset in the other makes its release a timing path between unrelated clocks, which no constraint can make safe. |
| **Both sides of the FIFO reset together** | The pointers live in both domains. Resetting one side alone leaves the other with a pointer the first no longer agrees with, and the FIFO presents words that were never written. |
| **Nothing crosses except through the FIFO** | The only crossings are the Gray-coded pointers inside `fifo_async` — the one kind of multi-bit crossing that is safe. |

## Interface

| Signal | Dir | Width | Domain | Description |
|---|---|---|---|---|
| `arst_n` | in | 1 | async | The one reset, raw, active low |
| `src_clk` | in | 1 | — | Source clock |
| `s_valid` / `s_ready` / `s_data` | in / out / in | 1 / 1 / `DATA_WIDTH` | `src_clk` | Input stream |
| `dst_clk` | in | 1 | — | Destination clock |
| `m_valid` / `m_ready` / `m_data` | out / in / out | 1 / 1 / `DATA_WIDTH` | `dst_clk` | Output stream |

## Verification

```bash
ctest --test-dir build -R 'cdc_stream_bridge'
```

`cocotb/test_cdc_stream_bridge.py` runs the two clocks at periods with no
small common factor, so the phase between their edges drifts through every
value during a run — the condition under which a crossing bug, rather than a
FIFO bug, shows up. It covers the reset state, a single word, a burst of four
FIFO depths into a slower destination, randomised traffic with back-pressure
on both sides in both rate directions, and a reset mid-stream that must leave
no phantom words behind.
