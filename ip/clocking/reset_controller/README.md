# reset_controller

Combines the reset sources of one clock domain and releases a staged reset tree
in a defined order.

A real SoC does not have one reset. It has a power-on reset, a software reset
written by the CPU, a watchdog timeout and usually a debug reset — and the
blocks they reset must come out of reset in a defined order. An interconnect
that starts before its slaves forwards transactions into blocks that are still
resetting; a DMA engine that starts before the interconnect issues reads that
go nowhere.

| | |
|---|---|
| **Category** | `clocking` |
| **Top module** | `reset_controller` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | this block *is* the reset path |
| **Latency** | stage *n* releases `MIN_ASSERT_CYCLES + n*STAGE_DELAY` cycles after the sources clear |
| **Depends on** | `cdc_reset_sync` |
| **Verified at** | 10.0 ns clock period |
| **Licence** | Apache-2.0 |

## What it provides

- **OR-combining** of an asynchronous source and a synchronous request, so
  combinational glitches never reach the reset tree.
- **A guaranteed minimum assertion time**, so a one-cycle software request
  still produces a reset long enough for every block to see it.
- **Synchronous release**, via the same asynchronous-assert / synchronous-
  release structure as `cdc_reset_sync`, which it reuses rather than
  reimplements.
- **Staged release** in ascending index order with `STAGE_DELAY` cycles
  between stages.

Assign stage 0 to the most fundamental blocks — clocking, memory controllers —
and the highest stage to the masters that drive traffic. On assertion all
stages assert together and immediately; only the release is sequenced. Bringing
a system down in stages would leave transactions in flight with no one to
answer them.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Domain clock |
| `arst_n_in` | in | 1 | Asynchronous reset sources, active low |
| `sw_reset` | in | 1 | Synchronous reset request, active high; one cycle is enough |
| `rst_n_out` | out | `NUM_STAGES` | Staged resets, active low; index 0 releases first |
| `reset_active` | out | 1 | High while any stage is still asserted |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `NUM_STAGES` | `int unsigned` | 4 | >= 1 | Number of staged outputs |
| `STAGE_DELAY` | `int unsigned` | 4 | >= 0 | Cycles between consecutive releases |
| `MIN_ASSERT_CYCLES` | `int unsigned` | 16 | >= 1 | Minimum assertion time |
| `SYNC_STAGES` | `int unsigned` | 3 | >= 2 | Synchroniser depth for the release edge |

## Quick start

```systemverilog
reset_controller #(
  .NUM_STAGES        (4),
  .STAGE_DELAY       (4),
  .MIN_ASSERT_CYCLES (16)
) u_rstctl (
  .clk          (clk_sys),
  .arst_n_in    (por_n & ~watchdog_timeout),
  .sw_reset     (cpu_soft_reset),
  .rst_n_out    ({rst_n_masters, rst_n_fabric, rst_n_slaves, rst_n_clocking}),
  .reset_active (system_in_reset)
);
```

Note the bit order: `rst_n_out[0]` is `rst_n_clocking` and releases first.

## Constraints

Apply [`scripts/reset_controller.sdc`](scripts/reset_controller.sdc).

## Verification

```bash
ctest --test-dir build -R 'reset_controller'
```

An order monitor runs for the whole regression, so a stage released out of turn
fails whichever test happens to be running.

- `cocotb/test_reset_controller.py` — every stage asserted while held, staged
  release with exact `STAGE_DELAY` spacing, a one-cycle request stretched to
  `MIN_ASSERT_CYCLES`, asynchronous assertion away from a clock edge,
  randomised software resets, and a repeatability check that every reset
  produces an identical release sequence.
- `tb/tb_reset_controller.sv` — portable smoke test with continuous order
  checking.

Full documentation: [`docs/index.rst`](docs/index.rst).
