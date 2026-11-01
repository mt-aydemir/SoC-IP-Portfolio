# adder

Parameterised combinational adder with carry in and out, signed and unsigned
modes, and optional saturation.

The block is deliberately combinational. An adder is a leaf: where it needs to
be registered, the register belongs to the pipeline stage that owns it, so
building one in would carry a clock and a reset through every instantiation
that does not want them and would fix the retiming boundary in the wrong place.

| | |
|---|---|
| **Category** | `arithmetic` |
| **Top module** | `adder` |
| **Clock domains** | 0 — purely combinational |
| **Reset** | none; the block has no state |
| **Latency** | combinational |
| **Throughput** | one result per cycle of the surrounding pipeline |
| **Verified at** | `WIDTH=16 SIGNED=1 SATURATE=1` |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `a` | in | `WIDTH` | First operand |
| `b` | in | `WIDTH` | Second operand |
| `carry_in` | in | 1 | Carry into the least significant bit |
| `sum` | out | `WIDTH` | Result, saturated when `SATURATE` is set |
| `carry_out` | out | 1 | Carry out of the most significant bit |
| `overflow` | out | 1 | Result was not representable |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `WIDTH` | `int unsigned` | 32 | >= 2 | Operand and result width |
| `SIGNED` | `int unsigned` | 0 | 0 or 1 | Two's complement interpretation, selecting the overflow rule and the saturation limits |
| `SATURATE` | `int unsigned` | 0 | 0 or 1 | Clamp on overflow instead of wrapping |

## Signed, unsigned and saturation

The sum itself is bit-identical in both interpretations — two's complement
addition does not care. What changes is what counts as an overflow, and
therefore what saturation does:

| | Overflow condition | Saturation limit |
|---|---|---|
| **unsigned** | carry out of the top bit | all-ones |
| **signed** | operands share a sign the result does not | most positive / most negative |

`carry_out` is always the real carry out of the top bit, in both
interpretations. Under `SIGNED` it carries no information about overflow, and
reading it as if it did is the classic defect this interface is shaped to
prevent: `overflow` is the signal to branch on.

## Quick start

```systemverilog
adder #(
  .WIDTH    (16),
  .SIGNED   (1),
  .SATURATE (1)
) u_add (
  .a         (sample),
  .b         (bias),
  .carry_in  (1'b0),
  .sum        (biased_sample),
  .carry_out  (),
  .overflow   (clipped)
);
```

## Verification

```bash
ctest --test-dir build -R 'adder'
```

- `cocotb/test_adder.py` — directed, randomised and regression suites against
  a reference model written from the specification rather than from the RTL.
- `tb/tb_adder.sv` — portable self-checking smoke test, no Python needed.

## Files

```
rtl/adder.sv          synthesisable RTL
tb/tb_adder.sv        SystemVerilog testbench
cocotb/test_adder.py  cocotb regression
docs/index.rst        full documentation
scripts/adder.sdc     timing constraints
```

Full documentation: [`docs/index.rst`](docs/index.rst).
