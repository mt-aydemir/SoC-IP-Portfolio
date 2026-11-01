# cdc_reset_sync

Reset synchroniser — asynchronous assertion, synchronous release.

A raw power-on or system reset is asynchronous to every clock in the design.
Asserting it asynchronously is wanted: the design reaches a known state even
before the clocks are running. Releasing it asynchronously is not — if the
release edge lands inside a flip-flop's recovery or removal window, that
flip-flop can go metastable, and different flip-flops can leave reset on
different cycles, which corrupts any state machine that assumes its bits left
reset together.

| | |
|---|---|
| **Category** | `cdc` |
| **Top module** | `cdc_reset_sync` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | this block *is* the reset path |
| **Latency** | assertion immediate; release `STAGES` cycles |
| **Verified at** | 10.0 ns clock period |
| **Licence** | Apache-2.0 |

**One instance per clock domain.** Feeding one domain's synchronised reset into
another does not work: the release edge would again be asynchronous to the
second domain.

## Interface

| Signal | Dir | Width | Domain | Description |
|---|---|---|---|---|
| `clk` | in | 1 | dest | Destination-domain clock |
| `arst_n_in` | in | 1 | **async** | Raw asynchronous reset, active low |
| `rst_n_out` | out | 1 | dest | Synchronised reset for this domain, active low |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `STAGES` | `int unsigned` | 2 | >= 2 | Chain length; also the release latency in cycles |

## Quick start

```systemverilog
cdc_reset_sync #(.STAGES(3)) u_rst_sync_core (
  .clk       (clk_core),
  .arst_n_in (por_n),        // raw power-on reset
  .rst_n_out (rst_n_core)    // distribute to the core clock domain
);
```

Distribute `rst_n_core` to every block in that domain. Never distribute the raw
asynchronous reset directly.

## Constraints

Apply [`scripts/cdc_reset_sync.sdc`](scripts/cdc_reset_sync.sdc). It declares
the asynchronous input as a false path and preserves the chain against
optimisation.

## Verification

```bash
ctest --test-dir build -R 'cdc_reset_sync'
```

- `cocotb/test_cdc_reset_sync.py` — held-low behaviour, exact release latency,
  asynchronous assertion away from a clock edge, sub-cycle glitch capture,
  randomised assertion phases, and back-to-back assert/release cycles.
- `tb/tb_cdc_reset_sync.sv` — portable self-checking smoke test.

Full documentation: [`docs/index.rst`](docs/index.rst).
