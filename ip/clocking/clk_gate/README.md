# clk_gate

Glitch-free clock gate.

Gating a clock with a plain AND gate is wrong. The enable is produced by
rising-edge logic, so it changes shortly after a rising clock edge — in the
middle of the clock's high phase. ANDing it with the clock therefore chops the
current pulse, and a runt pulse is narrower than the flip-flops downstream
require: they can go metastable, or only part of a register bank gets clocked.

Holding the enable in a latch that is transparent only while the clock is low
absorbs the change during the low phase, so the value presented to the AND gate
is already stable by the time the clock rises. This is exactly the structure of
an ASIC library's integrated clock gating cell, written so that any synthesiser
can infer it and no vendor primitive is required.

```text
clk       __/‾‾‾\___/‾‾‾\___/‾‾‾\___
enable    ______/‾‾‾‾‾‾‾‾‾\_________   changes mid-high-phase
naive AND ______/‾\___/‾‾‾\_________   runt pulse
latched   __________/‾‾‾‾‾‾‾‾‾\_____   updated only while clk is low
gated_clk __________/‾‾‾\___________   whole pulses only
```

| | |
|---|---|
| **Category** | `clocking` |
| **Top module** | `clk_gate` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | none; the block is stateless |
| **Verified at** | 10.0 ns clock period |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Source clock |
| `enable` | in | 1 | Clock enable, from rising-edge logic in the `clk` domain |
| `test_en` | in | 1 | Forces the gate open for scan; tie low functionally |
| `gated_clk` | out | 1 | Gated clock |

`test_en` exists so scan chains keep clocking during test regardless of the
functional enable. Never drive it from functional logic.

## Quick start

```systemverilog
clk_gate u_gate_dsp (
  .clk       (clk_sys),
  .enable    (dsp_active),
  .test_en   (scan_mode),
  .gated_clk (clk_dsp)
);
```

## Constraints

Apply [`scripts/clk_gate.sdc`](scripts/clk_gate.sdc). It declares `gated_clk`
as a generated clock and preserves the latch — an optimiser that converts it to
a flip-flop, or removes it, silently reintroduces the runt pulse.

## Verification

The measurement is the point. A functional check that merely counts edges
passes on a naive AND gate; only measuring the width of *every* pulse
distinguishes a correct clock gate from a broken one.

```bash
ctest --test-dir build -R 'clk_gate'
```

- `cocotb/test_clk_gate.py` — no edges while disabled, one gated edge per
  source edge while enabled, `test_en` forcing the gate open, the enable
  changed in the middle of the high phase, randomised enable phases, and a
  1000-cycle run in which every pulse width is checked.
- `tb/tb_clk_gate.sv` — portable smoke test measuring every pulse with
  `$realtime`.

Full documentation: [`docs/index.rst`](docs/index.rst).
