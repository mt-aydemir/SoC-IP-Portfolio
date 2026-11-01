# barrel_shifter

Combinational barrel shifter: logical and arithmetic shifts and rotates, in
either direction, by any amount in one cycle.

| | |
|---|---|
| **Category** | `arithmetic` |
| **Top module** | `barrel_shifter` |
| **Clock domains** | 0 — purely combinational |
| **Reset** | none; the block has no state |
| **Latency** | combinational |
| **Verified at** | `WIDTH=32` |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `data_in` | in | `WIDTH` | Data to shift or rotate |
| `amount` | in | `$clog2(WIDTH)` | Shift or rotate amount |
| `operation` | in | 3 | Operation select, encoded below |
| `data_out` | out | `WIDTH` | Result |

## Operations

| Code | Operation | Behaviour |
|---|---|---|
| 0 | `SHIFT_LEFT` | Zeros shifted in at the bottom |
| 1 | `SHIFT_RIGHT` | Zeros shifted in at the top (logical) |
| 2 | `ARITH_RIGHT` | The sign bit replicated at the top |
| 3 | `ROTATE_LEFT` | Bits leaving the top re-enter at the bottom |
| 4 | `ROTATE_RIGHT` | Bits leaving the bottom re-enter at the top |
| 5–7 | *unused* | `data_in` passed through unchanged |

An arithmetic **left** shift is deliberately absent: it is identical to a
logical left shift, and offering both would suggest a difference that does not
exist.

The three unused codes are specified as a pass-through rather than left to
chance. That is what keeps the block free of inferred latches and makes an
out-of-range opcode a visible identity rather than an undefined result.

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `WIDTH` | `int unsigned` | 32 | >= 2 | Data width. The amount port is `$clog2(WIDTH)` bits wide. |

## Shift amount

The amount is `$clog2(WIDTH)` bits wide, so every representable amount is in
range for a power-of-two `WIDTH`. For a non-power-of-two `WIDTH` the encoding
can express amounts of `WIDTH` or more; those produce the fully shifted result
(all zeros, or all sign bits) for the shifts, and are reduced modulo `WIDTH`
for the rotates — the only definition that keeps a rotate reversible.

## Implementation note

A barrel shifter is a tree of multiplexer stages, one per bit of the shift
amount: stage *k* either passes its input through or shifts it by 2^*k*. That
structure is what makes the delay logarithmic in `WIDTH` rather than linear,
and it is what `<<`, `>>` and `>>>` infer on every synthesiser worth using.

The operators are therefore used directly. A hand-built mux tree would be
larger, slower and harder to read, and would defeat any target that has a
dedicated shifter.

## Quick start

```systemverilog
barrel_shifter #(
  .WIDTH (32)
) u_shift (
  .data_in   (operand),
  .amount    (shift_amount),
  .operation (3'd2),          // arithmetic right
  .data_out  (scaled)
);
```

## Verification

```bash
ctest --test-dir build -R 'barrel_shifter'
```

- `cocotb/test_barrel_shifter.py` — every operation at zero, one and the
  extremes; the sign-extension behaviour of the arithmetic right shift; an
  exhaustive sweep of every `(operation, amount)` pair; a single-bit walk; and
  the rotate round-trip and population-count identities.
- `tb/tb_barrel_shifter.sv` — portable self-checking smoke test whose
  reference model builds the result one bit at a time, so it shares nothing
  with the design's use of the shift operators.

## Files

```
rtl/barrel_shifter.sv          synthesisable RTL
tb/tb_barrel_shifter.sv        SystemVerilog testbench
cocotb/test_barrel_shifter.py  cocotb regression
docs/index.rst                 full documentation
scripts/barrel_shifter.sdc     timing constraints
```

Full documentation: [`docs/index.rst`](docs/index.rst).
