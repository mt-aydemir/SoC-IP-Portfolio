# mac

Multiply-accumulate: `acc <- acc + a*b`, with optional saturation and a wider
accumulator than the product.

The multiply-accumulate is the inner loop of every filter, correlation and
matrix product, which is why it exists as a block rather than as two blocks
wired together by each caller: getting the accumulator width and the clear
timing right is the part people get wrong, and doing it once here means doing
it right once.

| | |
|---|---|
| **Category** | `arithmetic` |
| **Top module** | `mac` |
| **Depends on** | `multiplier`, `accumulator` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | 2 cycles from operands to the updated `acc_out` |
| **Throughput** | one multiply-accumulate per cycle |
| **Verified at** | `A_WIDTH=16 B_WIDTH=16 ACC_WIDTH=40 SIGNED=1` |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Rising-edge clock |
| `rst_n` | in | 1 | Active-low reset |
| `in_valid` | in | 1 | Operands are valid this cycle |
| `clear` | in | 1 | Start a new total **with this sample** |
| `a` | in | `A_WIDTH` | First operand |
| `b` | in | `B_WIDTH` | Second operand |
| `out_valid` | out | 1 | `acc_out` was updated this cycle |
| `acc_out` | out | `ACC_WIDTH` | The running total |
| `overflow` | out | 1 | The accumulation on this edge was not representable |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `A_WIDTH` | `int unsigned` | 16 | >= 1 | First operand width |
| `B_WIDTH` | `int unsigned` | 16 | >= 1 | Second operand width |
| `ACC_WIDTH` | `int unsigned` | 40 | >= `A_WIDTH + B_WIDTH` | Accumulator width |
| `SIGNED` | `int unsigned` | 1 | 0 or 1 | Interpret operands as two's complement |
| `SATURATE` | `int unsigned` | 0 | 0 or 1 | Clamp the accumulator instead of wrapping |

## Clear alignment — the reason this block exists

`clear` is asserted by the caller **alongside the first sample of a new
frame**, not a cycle before it. Inside the block the clear is delayed by
exactly the multiplier's latency, so it reaches the accumulator in the same
cycle as the product it is meant to precede.

Without that alignment:

- a clear arriving one cycle **early** wipes the accumulator *after* the last
  product of the previous frame has already been added — so the previous
  frame's total is short by its last term;
- a clear arriving one cycle **late** wipes it *after* the new frame's first
  product has been added — so the new frame's total is missing its first term.

Both failures produce results that look almost right, which is what makes them
expensive to find in a system. `cocotb/test_mac.py::test_clear_alignment`
pushes two frames back to back with no gap and fails on either.

The clear is implemented as a `load` of the first product rather than a zero
followed by an accumulate, so starting a frame costs no cycle and discards no
sample.

## Accumulator width

The product needs `A_WIDTH + B_WIDTH` bits. Accumulating *N* of them needs
another `$clog2(N)` on top. `ACC_WIDTH` is the caller's decision because only
the caller knows *N*; the block checks that it is at least wide enough for a
single product and reports `overflow` if the real total exceeds it.

For a 16×16 filter with 128 taps that is 32 + 7 = 39 bits, so `ACC_WIDTH` of
40 is the honest choice and 32 is the common mistake.

## Quick start

```systemverilog
mac #(
  .A_WIDTH   (16),
  .B_WIDTH   (16),
  .ACC_WIDTH (40),
  .SIGNED    (1),
  .SATURATE  (1)
) u_mac (
  .clk       (clk),
  .rst_n     (rst_n),
  .in_valid  (sample_valid),
  .clear     (first_tap),        // asserted WITH the first sample
  .a         (sample),
  .b         (coefficient),
  .out_valid (acc_valid),
  .acc_out   (filter_output),
  .overflow  (acc_clipped)
);
```

## Verification

```bash
ctest --test-dir build -R 'mac'
```

- `cocotb/test_mac.py` — a cycle-accurate model of the *structure* (one
  multiplier stage, a clear travelling with it, then the accumulate), compared
  after every edge. Covers the reset state, the two-cycle latency counted in
  edges, a hand-computed dot product, the clear alignment across a
  zero-gap frame boundary, back-to-back frames, gaps inside a frame, random
  frames, independently drawn `in_valid`/`clear` (which produces clear
  patterns no well-behaved caller would generate, all of which are legal), the
  accumulator limits, a mid-stream reset and a 2000-cycle run.
- `tb/tb_mac.sv` — portable self-checking smoke test with the same structural
  reference model and 3000 randomised control vectors.

## Files

```
rtl/mac.sv          synthesisable RTL
tb/tb_mac.sv        SystemVerilog testbench
cocotb/test_mac.py  cocotb regression
docs/index.rst      full documentation
scripts/mac.sdc     timing constraints
```

Full documentation: [`docs/index.rst`](docs/index.rst).
