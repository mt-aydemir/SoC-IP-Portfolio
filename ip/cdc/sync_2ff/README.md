# cdc_sync_2ff

Multi-flop synchroniser for asynchronous single-bit signals.

Transfers one or more *independent* asynchronous bits into the destination
clock domain through a chain of `STAGES` flip-flops. The first flip-flop may go
metastable; each additional stage gives the metastability a further full clock
period to resolve, which is what makes the mean time between failures
astronomically large.

| | |
|---|---|
| **Category** | `cdc` |
| **Top module** | `cdc_sync_2ff` |
| **Clock domains** | 1 destination clock (`clk`); the input is asynchronous |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | `STAGES` destination clock cycles |
| **Verified at** | 4.0 ns clock period |
| **Licence** | Apache-2.0 |

## Usage rule

**This block is only correct for signals whose bits are mutually independent** —
a level-encoded status flag, or a set of unrelated interrupt lines.

It must **not** be used to transfer a multi-bit value whose bits change
together. Each bit resolves independently, so the destination domain can
observe a combination that never existed at the source. For multi-bit data use:

| Traffic | Block |
|---|---|
| A single event or pulse | `cdc_pulse_sync` |
| A value transferred on request | `cdc_handshake` |
| A continuous data stream | `fifo_async` |
| A free-running counter | Gray-code it, then cross with this block |

The Gray-code case is safe because adjacent codes differ by exactly one bit, so
a partially resolved sample is always either the old value or the new one.

## Interface

| Signal | Dir | Width | Domain | Description |
|---|---|---|---|---|
| `clk` | in | 1 | dest | Destination-domain clock |
| `rst_n` | in | 1 | async | Active-low reset |
| `d_async` | in | `WIDTH` | async | Asynchronous input, sampled by the first stage |
| `q_sync` | out | `WIDTH` | dest | Synchronised output |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `WIDTH` | `int unsigned` | 1 | >= 1 | Number of independent bits to synchronise |
| `STAGES` | `int unsigned` | 2 | >= 2 | Length of the flip-flop chain |
| `RESET_VALUE` | `logic [WIDTH-1:0]` | `'0` | any | Value loaded into every stage during reset |

Two stages is the industry minimum. Three is common for high clock rates or
high reliability targets.

## Quick start

```systemverilog
cdc_sync_2ff #(
  .WIDTH  (1),
  .STAGES (3)
) u_sync_busy (
  .clk     (clk_cpu),
  .rst_n   (rst_n_cpu),
  .d_async (busy_from_periph),   // driven in another clock domain
  .q_sync  (busy_seen_by_cpu)
);
```

## Constraints

Synchroniser chains must not be retimed, merged or spread across the die.
Apply [`scripts/cdc_sync_2ff.sdc`](scripts/cdc_sync_2ff.sdc), which bounds
the source-to-first-flop segment at one destination period in place of the
setup check (or cuts it, if the destination clock is not given).

## Verification

```bash
ctest --test-dir build -R 'cdc_sync_2ff'
```

- `cocotb/test_cdc_sync_2ff.py` — reset state and `RESET_VALUE` handling, exact
  propagation latency, randomised traffic against a shift-register model,
  worst-case every-cycle toggling, lane independence, and asynchronous reset
  asserted mid-traffic.
- `tb/tb_cdc_sync_2ff.sv` — portable self-checking smoke test.

Full documentation: [`docs/index.rst`](docs/index.rst).
