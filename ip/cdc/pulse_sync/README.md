# cdc_pulse_sync

Transfers a single-cycle pulse (an event) between clock domains of arbitrary,
unrelated frequencies.

A pulse cannot be carried across a domain boundary by a plain synchroniser. If
the source clock is faster than the destination, a one-cycle pulse can fall
entirely between two destination sampling edges and be lost. If the source is
slower, the same pulse is sampled on several consecutive destination edges and
arrives as a burst.

This block converts the event into a level toggle, which survives any clock
ratio, and feeds the destination's copy of the toggle back to the source so
that no event is ever overwritten by the next one.

| | |
|---|---|
| **Category** | `cdc` |
| **Top module** | `cdc_pulse_sync` |
| **Clock domains** | 2 (`src_clk`, `dst_clk`), unrelated |
| **Reset** | `src_rst_n` / `dst_rst_n`, active low, one per domain |
| **Latency** | 2–3 src cycles + `STAGES` dst cycles |
| **Throughput** | one event per round trip — check `src_busy` |
| **Depends on** | `cdc_sync_2ff` |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Domain | Description |
|---|---|---|---|---|
| `src_clk` | in | 1 | src | Source clock |
| `src_rst_n` | in | 1 | src | Source reset, active low |
| `src_pulse` | in | 1 | src | One-cycle request; ignored while `src_busy` |
| `src_busy` | out | 1 | src | An event is in flight; do not present another |
| `dst_clk` | in | 1 | dst | Destination clock |
| `dst_rst_n` | in | 1 | dst | Destination reset, active low |
| `dst_pulse` | out | 1 | dst | One-cycle pulse, one per accepted `src_pulse` |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `STAGES` | `int unsigned` | 2 | >= 2 | Synchroniser depth, used in both directions |

## The busy rule

`src_busy` is not advisory. An event presented while busy is **dropped**, and
an assertion fires in simulation. Accepting it would toggle the source
flip-flop back to its previous value, so the destination would see no edge at
all and *both* events would vanish. Dropping one and saying so is the lesser
evil.

```systemverilog
if (event_ready && !src_busy) begin
  src_pulse <= 1'b1;
end
```

If events can arrive faster than the round trip, buffer them in the source
domain, or use `fifo_async` instead.

## Quick start

```systemverilog
cdc_pulse_sync #(.STAGES(2)) u_irq_sync (
  .src_clk   (clk_periph),
  .src_rst_n (rst_n_periph),
  .src_pulse (irq_event),
  .src_busy  (irq_busy),
  .dst_clk   (clk_cpu),
  .dst_rst_n (rst_n_cpu),
  .dst_pulse (irq_to_cpu)
);
```

## Constraints

Apply [`scripts/cdc_pulse_sync.sdc`](scripts/cdc_pulse_sync.sdc): both
crossings are false paths with a bounded source-to-first-flop delay.

## Verification

```bash
ctest --test-dir build -R 'cdc_pulse_sync'
```

Every test runs at three clock ratios — destination faster, destination slower,
and nearly equal — because a pulse synchroniser that works at one ratio can
silently drop or duplicate events at another.

- `cocotb/test_cdc_pulse_sync.py` — reset state, a single event, the busy
  handshake, randomised events at random gaps, maximum-rate bursts, and an
  event presented immediately after reset release.
- `tb/tb_cdc_pulse_sync.sv` — portable self-checking smoke test with a 10 ns
  source and 27 ns destination clock.

Full documentation: [`docs/index.rst`](docs/index.rst).
