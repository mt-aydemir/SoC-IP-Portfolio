# subtractor

Parameterised combinational subtractor with borrow in and out, signed and
unsigned modes, and optional saturation.

The block instantiates [`adder`](../adder) rather than building a second carry
chain. Two's complement subtraction is addition of the inverted subtrahend
with the carry in set:

```
a - b - borrow_in  ==  a + ~b + ~borrow_in
```

| | |
|---|---|
| **Category** | `arithmetic` |
| **Top module** | `subtractor` |
| **Depends on** | `adder` |
| **Clock domains** | 0 — purely combinational |
| **Reset** | none; the block has no state |
| **Latency** | combinational |
| **Verified at** | `WIDTH=16 SIGNED=1 SATURATE=1`, and in the unsigned configuration |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `a` | in | `WIDTH` | Minuend |
| `b` | in | `WIDTH` | Subtrahend |
| `borrow_in` | in | 1 | Borrow into the least significant bit |
| `difference` | out | `WIDTH` | Result, saturated when `SATURATE` is set |
| `borrow_out` | out | 1 | The result went below zero |
| `overflow` | out | 1 | The result was not representable |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `WIDTH` | `int unsigned` | 32 | >= 2 | Operand and result width |
| `SIGNED` | `int unsigned` | 0 | 0 or 1 | Two's complement interpretation |
| `SATURATE` | `int unsigned` | 0 | 0 or 1 | Clamp on overflow instead of wrapping |

## What the adder does not supply

Three things do not come for free from the shared adder and are handled here:

| | |
|---|---|
| **`borrow_out`** | The adder produces a carry; for a subtraction the borrow is its complement. No carry out means the result went below zero. |
| **unsigned saturation** | The adder clamps an unsigned overflow to all-ones, which is the right limit for addition and the wrong one for subtraction. An unsigned result that goes below zero clamps to **zero**. |
| **unsigned `overflow`** | The adder reports unsigned overflow as its carry out, which is inverted for a subtraction. The flag is taken from `borrow_out` instead. |

Signed overflow needs no special handling: the adder's condition — the two
operands share a sign that the result does not — evaluated on `(a, ~b)` is
exactly the signed subtraction overflow condition, because `~b` has the
opposite sign bit to `b`.

## Quick start

```systemverilog
subtractor #(
  .WIDTH    (16),
  .SIGNED   (0),
  .SATURATE (1)
) u_sub (
  .a          (level),
  .b          (decay),
  .borrow_in  (1'b0),
  .difference (next_level),   // clamps at zero instead of wrapping
  .borrow_out (floor_reached),
  .overflow   ()
);
```

## Verification

```bash
ctest --test-dir build -R 'subtractor'
```

- `cocotb/test_subtractor.py` — directed, randomised and regression suites
  against a reference model that computes the exact difference in unbounded
  integers and asks whether it was representable, sharing none of the design's
  inverted-operand reasoning.
- `tb/tb_subtractor.sv` — portable self-checking smoke test, no Python needed.

That independence is what caught the inverted unsigned `overflow` flag
recorded in [`CHANGELOG.md`](CHANGELOG.md).

## Files

```
rtl/subtractor.sv          synthesisable RTL
tb/tb_subtractor.sv        SystemVerilog testbench
cocotb/test_subtractor.py  cocotb regression
docs/index.rst             full documentation
scripts/subtractor.sdc     timing constraints
```

Full documentation: [`docs/index.rst`](docs/index.rst).
