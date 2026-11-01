# cdc_handshake

Transfers a multi-bit value between clock domains using a four-phase
request/acknowledge handshake.

A multi-bit value must never cross a domain boundary through a bank of
synchronisers: each bit resolves independently, so the destination can sample a
combination that never existed at the source.

This block avoids that by never letting the data path cross asynchronously at
all. Only two single-bit control signals are synchronised — a request and an
acknowledge — and the payload sits in a source-domain register that is
guaranteed stable for the whole window in which the destination is allowed to
read it. The destination therefore samples a static value, and the data path
needs no synchroniser.

| | |
|---|---|
| **Category** | `cdc` |
| **Top module** | `cdc_handshake` |
| **Clock domains** | 2 (`src_clk`, `dst_clk`), unrelated |
| **Reset** | `src_rst_n` / `dst_rst_n`, active low, one per domain |
| **Latency** | `STAGES` dst cycles from request to `dst_valid` |
| **Throughput** | one word per round trip — not a streaming interface |
| **Depends on** | `cdc_sync_2ff` |
| **Licence** | Apache-2.0 |

## When to use this, and when not to

| Situation | Use |
|---|---|
| Occasional transfers, buffering not wanted | `cdc_handshake` |
| Continuous data stream | `fifo_async` |
| A single event with no payload | `cdc_pulse_sync` |
| One independent status bit | `cdc_sync_2ff` |

A handshake pays the full round-trip latency on *every* word. It costs two
flip-flop chains and one register rather than a dual-port memory, which is the
right trade when transfers are rare and area matters.

## Interface

| Signal | Dir | Width | Domain | Description |
|---|---|---|---|---|
| `src_clk` | in | 1 | src | Source clock |
| `src_rst_n` | in | 1 | src | Source reset, active low |
| `src_valid` | in | 1 | src | Source payload is valid |
| `src_ready` | out | 1 | src | Block will accept a word this cycle |
| `src_data` | in | `DATA_WIDTH` | src | Source payload |
| `dst_clk` | in | 1 | dst | Destination clock |
| `dst_rst_n` | in | 1 | dst | Destination reset, active low |
| `dst_valid` | out | 1 | dst | Destination payload is valid |
| `dst_ready` | in | 1 | dst | Consumer accepts a word this cycle |
| `dst_data` | out | `DATA_WIDTH` | dst | Destination payload |

Both sides are ordinary ready/valid streams with AXI4-Stream semantics.

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_WIDTH` | `int unsigned` | 32 | >= 1 | Payload width |
| `STAGES` | `int unsigned` | 2 | >= 2 | Synchroniser depth, both directions |

## Quick start

```systemverilog
cdc_handshake #(
  .DATA_WIDTH (32),
  .STAGES     (2)
) u_cfg_cross (
  .src_clk   (clk_cpu),
  .src_rst_n (rst_n_cpu),
  .src_valid (cfg_valid),
  .src_ready (cfg_ready),
  .src_data  (cfg_word),
  .dst_clk   (clk_dsp),
  .dst_rst_n (rst_n_dsp),
  .dst_valid (dsp_cfg_valid),
  .dst_ready (dsp_cfg_ready),
  .dst_data  (dsp_cfg_word)
);
```

## Constraints

Apply [`scripts/cdc_handshake.sdc`](scripts/cdc_handshake.sdc). It bounds the
delay into each synchroniser and — the part that is easy to forget — bounds the
payload register to destination capture path, which crosses domains without a
synchroniser by design. The clocks are not put in an asynchronous clock group:
that would override the bounds.

## Verification

```bash
ctest --test-dir build -R 'cdc_handshake'
```

- `cocotb/test_cdc_handshake.py` — reset state, a single word, the source
  closing for the whole round trip, destination back-pressure holding the
  payload, randomised streams at three clock ratios, order and count
  preservation over 300 words, and recovery after a reset.
- `tb/tb_cdc_handshake.sv` — portable self-checking smoke test at 10 ns / 23 ns.

Full documentation: [`docs/index.rst`](docs/index.rst).
