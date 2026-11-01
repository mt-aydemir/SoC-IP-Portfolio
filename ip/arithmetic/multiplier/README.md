# multiplier

Parameterised pipelined multiplier, signed or unsigned, with a configurable
number of pipeline stages.

| | |
|---|---|
| **Category** | `arithmetic` |
| **Top module** | `multiplier` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | `LATENCY` cycles |
| **Throughput** | one multiplication per cycle |
| **Verified at** | `A_WIDTH=16 B_WIDTH=16 SIGNED=1 LATENCY=2` |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Rising-edge clock |
| `rst_n` | in | 1 | Active-low reset |
| `in_valid` | in | 1 | Operands are valid this cycle |
| `a` | in | `A_WIDTH` | First operand |
| `b` | in | `B_WIDTH` | Second operand |
| `out_valid` | out | 1 | `product` is valid this cycle |
| `product` | out | `A_WIDTH+B_WIDTH` | Result |

There is no back-pressure: the pipeline accepts a pair every cycle and cannot
stall. `in_valid` is pipelined alongside the data, so the caller does not have
to track the latency by hand.

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `A_WIDTH` | `int unsigned` | 16 | >= 1 | Width of the first operand |
| `B_WIDTH` | `int unsigned` | 16 | >= 1 | Width of the second operand |
| `SIGNED` | `int unsigned` | 0 | 0 or 1 | Interpret both operands as two's complement |
| `LATENCY` | `int unsigned` | 1 | >= 1 | Pipeline registers on the output |

## Width

The product is `A_WIDTH + B_WIDTH` bits, which is always wide enough: the
largest magnitude product of an *m*-bit and an *n*-bit value fits in *m+n*
bits in both interpretations. **No overflow is possible and none is reported.**

## Implementation notes

**The product uses `*`.** Every synthesiser recognises the operator and maps
it onto whatever the target does best — a DSP slice on an FPGA, a
Booth-encoded Wallace tree on an ASIC. Any hand-written partial-product array
would be worse on at least one of those and would defeat the mapping on all of
them.

**Both operands are widened before multiplying.** This is what makes the
signed case correct. A signed multiply must sign extend both operands, and
SystemVerilog makes an expression unsigned if *any* operand is unsigned — so a
signed multiply written without explicit extension silently produces a huge
positive product whenever an operand is negative.

**The pipeline is a plain shift register on the result.** Retiming is the
tool's job: given registers on the output, synthesis distributes them through
the partial-product tree far better than hand placement can, and on an FPGA it
pushes them into the DSP slice's own pipeline registers where they cost
nothing at all.

## Quick start

```systemverilog
multiplier #(
  .A_WIDTH (16),
  .B_WIDTH (16),
  .SIGNED  (1),
  .LATENCY (2)
) u_mul (
  .clk       (clk),
  .rst_n     (rst_n),
  .in_valid  (sample_valid),
  .a         (sample),
  .b         (coefficient),
  .out_valid (product_valid),
  .product   (product)
);
```

## Verification

```bash
ctest --test-dir build -R 'multiplier'
```

- `cocotb/test_multiplier.py` — the reset state; the latency, counted in
  edges rather than by waiting for `out_valid`; identities; the four sign
  combinations at the extremes; full-rate and gapped randomised traffic; an
  exhaustive sweep at narrow widths; a mid-stream reset; and a 2000-pair
  sustained run.
- `tb/tb_multiplier.sv` — portable self-checking smoke test using an in-order
  queue of expected products, which checks the pipeline's ordering and latency
  as well as its arithmetic.

What is really under test is not the multiplication — a synthesiser maps `*`
onto hardware that is correct by construction — but the three things around it
that are easy to get wrong: the sign extension, the alignment of `product`
with `out_valid`, and the `LATENCY = 1` case where the usual
concatenation-based shift register would be malformed.

## Files

```
rtl/multiplier.sv          synthesisable RTL
tb/tb_multiplier.sv        SystemVerilog testbench
cocotb/test_multiplier.py  cocotb regression
docs/index.rst             full documentation
scripts/multiplier.sdc     timing constraints
```

Full documentation: [`docs/index.rst`](docs/index.rst).
