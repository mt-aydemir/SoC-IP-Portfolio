# comparator

Parameterised combinational magnitude comparator producing all six relational
results at once, signed or unsigned.

All six outputs are produced together because they share almost all of their
logic: a single subtraction settles every relation, and the outputs are then a
handful of gates on its result. Callers that need only one relation lose
nothing — the unused outputs have no load, so synthesis removes the gates
behind them.

| | |
|---|---|
| **Category** | `arithmetic` |
| **Top module** | `comparator` |
| **Clock domains** | 0 — purely combinational |
| **Reset** | none; the block has no state |
| **Latency** | combinational |
| **Verified at** | `WIDTH=16 SIGNED=1` |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `a` | in | `WIDTH` | First operand |
| `b` | in | `WIDTH` | Second operand |
| `equal` | out | 1 | `a == b` |
| `not_equal` | out | 1 | `a != b` |
| `less` | out | 1 | `a < b` |
| `less_equal` | out | 1 | `a <= b` |
| `greater` | out | 1 | `a > b` |
| `greater_equal` | out | 1 | `a >= b` |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `WIDTH` | `int unsigned` | 32 | >= 1 | Operand width |
| `SIGNED` | `int unsigned` | 0 | 0 or 1 | Interpret both operands as two's complement |

## Signed and unsigned

Equality is the same in both interpretations — two bit patterns are equal or
they are not. Ordering is not: `0xFF` is 255 unsigned and −1 signed, so it is
the largest value or the smallest according only to how it is read.

Getting this wrong is one of the most common defects in hand-written
comparison logic, which is why it is a parameter here rather than something
the caller is expected to arrange. The RTL also avoids the trap that makes it
so easy to get wrong: the two orderings are written as separately typed
comparisons selected by a generate, because SystemVerilog makes an expression
unsigned if *any* operand is unsigned, so a single comparison written to "work
for both" silently becomes the unsigned one.

## Quick start

```systemverilog
comparator #(
  .WIDTH  (12),
  .SIGNED (1)
) u_limit (
  .a             (measurement),
  .b             (threshold),
  .equal         (),
  .not_equal     (),
  .less          (),
  .less_equal    (),
  .greater       (over_threshold),
  .greater_equal ()
);
```

## Verification

```bash
ctest --test-dir build -R 'comparator'
```

- `cocotb/test_comparator.py` — directed, randomised and regression suites,
  including the trichotomy and antisymmetry properties that catch a signedness
  mistake without the test having to know the right answer.
- `tb/tb_comparator.sv` — portable self-checking smoke test, no Python needed.

The RTL carries a concurrent trichotomy check of its own, so an integrator who
drives it with mixed interpretations sees the violation in their own
simulation.

## Files

```
rtl/comparator.sv          synthesisable RTL
tb/tb_comparator.sv        SystemVerilog testbench
cocotb/test_comparator.py  cocotb regression
docs/index.rst             full documentation
scripts/comparator.sdc     timing constraints
```

Full documentation: [`docs/index.rst`](docs/index.rst).
