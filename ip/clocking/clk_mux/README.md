# clk_mux

Glitch-free multiplexer between two asynchronous clocks.

Switching clocks with a plain multiplexer produces a glitch whenever the select
changes while either clock is high: the output jumps from one clock's level to
the other's, which can create a pulse arbitrarily narrower than either source
period. Downstream flip-flops then see an edge that violates their minimum
pulse width, and the result is silent, unreproducible corruption.

This block makes the two clocks cooperate. Each owns a synchroniser holding its
own "I am selected" flag, each flag is qualified with the other's inverted, and
the final stage of each chain is clocked on the falling edge so the enable
changes only while its own clock is low.

| | |
|---|---|
| **Category** | `clocking` |
| **Top module** | `clk_mux` |
| **Clock domains** | 2 (`clk0`, `clk1`), unrelated |
| **Reset** | `rst0_n` / `rst1_n`, active low, one per branch. Reset selects `clk0` |
| **Latency** | ~`STAGES` cycles of each clock; output low during the changeover |
| **Verified at** | 10 ns / 27 ns |
| **Licence** | Apache-2.0 |

## Usage rule

**`select` must be held stable until `clk_active` has followed it.** This is a
requirement of every glitch-free clock multiplexer, including hard macro cells,
and it is why `clk_active` exists — it reports which clock is actually driving
the output, so the integrator never has to guess when the changeover finished.

```systemverilog
always_ff @(posedge clk_cfg or negedge rst_n_cfg)
  if (!rst_n_cfg)                rst_select <= 1'b0;
  else if (select == clk_active) select     <= requested_clock;
```

Withdrawing a request mid-changeover is handled safely — each branch's chain is
cleared rather than shifted, so no stale request can complete behind the
withdrawal — but it simply delays the switch.

Both clocks must be running for a changeover to complete. If the incoming clock
is dead the block never finishes the switch and holds the output low, which is
the safe failure.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk0` | in | 1 | Clock 0, selected by reset |
| `clk1` | in | 1 | Clock 1 |
| `rst0_n` | in | 1 | Reset for branch 0, released synchronously to `clk0` |
| `rst1_n` | in | 1 | Reset for branch 1, released synchronously to `clk1` |
| `select` | in | 1 | Requested clock; asynchronous, synchronised internally |
| `clk_active` | out | 1 | Which clock is driving the output |
| `clk_out` | out | 1 | Selected clock |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `STAGES` | `int unsigned` | 2 | >= 2 | Synchroniser depth in each branch |

## Quick start

```systemverilog
clk_mux #(.STAGES(2)) u_clk_sel (
  .clk0       (clk_ref),
  .clk1       (clk_pll),
  .rst0_n     (rst_n_ref),
  .rst1_n     (rst_n_pll),
  .select     (use_pll),
  .clk_active (pll_is_live),
  .clk_out    (clk_core)
);
```

## Constraints

Apply [`scripts/clk_mux.sdc`](scripts/clk_mux.sdc): the two clocks are
asynchronous, `clk_out` is a generated clock derived from both, and both
synchroniser chains must be preserved.

## Verification

Every test runs with a phase monitor attached. The output may be *slow* during
the dead time between one clock releasing and the other taking over, but never
*fast*: any phase shorter than the narrowest source phase is a runt.

```bash
ctest --test-dir build -R 'clk_mux'
```

- `cocotb/test_clk_mux.py` — reset selects `clk0`, switching both ways with
  `clk_active` reporting it, 20 back-to-back switches, randomised switching,
  the usage rule deliberately violated 200 times, and a stalled source clock.
- `tb/tb_clk_mux.sv` — portable smoke test at 10 ns / 27 ns measuring every
  output phase.

Full documentation: [`docs/index.rst`](docs/index.rst).
