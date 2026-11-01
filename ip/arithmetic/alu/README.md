# alu

Combinational arithmetic and logic unit with condition flags.

A datapath ALU: one operation per cycle selected by an opcode, with the four
classical condition flags produced alongside the result. It is built from the
portfolio's single [`adder`](../adder) and [`barrel_shifter`](../barrel_shifter)
rather than its own copies, so there is one implementation of two's complement
addition with overflow detection in the library, and one shifter.

| | |
|---|---|
| **Category** | `arithmetic` |
| **Top module** | `alu` |
| **Depends on** | `adder`, `barrel_shifter` |
| **Clock domains** | 0 — purely combinational |
| **Reset** | none; the block has no state |
| **Latency** | combinational |
| **Verified at** | `WIDTH=32` |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `a` | in | `WIDTH` | First operand; the value shifted by the shift opcodes |
| `b` | in | `WIDTH` | Second operand; its low `$clog2(WIDTH)` bits are the shift amount |
| `opcode` | in | 4 | Operation select |
| `carry_in` | in | 1 | Carry into `ADD`, "no borrow" into `SUB` |
| `result` | out | `WIDTH` | Result |
| `flag_zero` | out | 1 | Z — result is zero |
| `flag_negative` | out | 1 | N — result's most significant bit |
| `flag_carry` | out | 1 | C — carry out (`ADD`), no borrow (`SUB`); 0 otherwise |
| `flag_overflow` | out | 1 | V — signed result not representable (`ADD`, `SUB`); 0 otherwise |

## Opcodes

| Code | Name | Result | Code | Name | Result |
|---|---|---|---|---|---|
| `0x0` | `ADD` | `a + b + carry_in` | `0x8` | `SRA` | `a >>> b`, arithmetic |
| `0x1` | `SUB` | `a - b - !carry_in` | `0x9` | `ROL` | `a` rotated left by `b` |
| `0x2` | `AND` | `a & b` | `0xA` | `ROR` | `a` rotated right by `b` |
| `0x3` | `OR` | `a \| b` | `0xB` | `SLT` | signed `a < b` → 1 |
| `0x4` | `XOR` | `a ^ b` | `0xC` | `SLTU` | unsigned `a < b` → 1 |
| `0x5` | `NOT` | `~a` | `0xD` | `PASS` | `a` |
| `0x6` | `SLL` | `a << b` | `0xE` | `PASSB` | `b` |
| `0x7` | `SRL` | `a >> b`, logical | `0xF` | — | `0` |

## Flag conventions

Flag semantics are the part of an ALU most often got wrong, because they
differ between architectures and the difference is invisible until a
conditional branch behaves oddly.

- **C for subtraction is the inverted borrow** — the ARM and x86 convention,
  not the 6502 one — so "carry set" means "no borrow". `carry_in` into `SUB`
  follows the same convention: drive 1 for a plain subtraction, and the
  previous word's carry when chaining.
- **C and V are cleared by every non-arithmetic opcode** rather than left
  stale, so a consumer never has to remember which opcode last wrote them.
- **`SLT` is N XOR V of the subtraction**, not the sign bit alone: when the
  subtraction overflows, the sign bit is the opposite of the true sign.

## Multi-word arithmetic

```
low  = ALU(ADD, a_lo, b_lo, carry_in = 0)   -> C
high = ALU(ADD, a_hi, b_hi, carry_in = C)

low  = ALU(SUB, a_lo, b_lo, carry_in = 1)   -> C  (1 = no borrow)
high = ALU(SUB, a_hi, b_hi, carry_in = C)
```

## Quick start

```systemverilog
alu #(
  .WIDTH (32)
) u_alu (
  .a             (rs1_value),
  .b             (rs2_value),
  .opcode        (alu_op),
  .carry_in      (alu_op == 4'h1),   // plain SUB: no incoming borrow
  .result        (alu_result),
  .flag_zero     (z),
  .flag_negative (n),
  .flag_carry    (c),
  .flag_overflow (v)
);
```

## Verification

```bash
ctest --test-dir build -R 'alu'
```

- `cocotb/test_alu.py` — every opcode, flag clearing, the carry convention,
  double-width add and subtract chained through `carry_in`, the comparisons
  where signed and unsigned disagree, randomised operations, an exhaustive
  sweep at narrow widths, and a statelessness check.
- `tb/tb_alu.sv` — portable self-checking smoke test covering every opcode
  and carry value across the operand space at `WIDTH=8`.

The multi-word test is what found that `SUB` ignored `carry_in`; see
[`CHANGELOG.md`](CHANGELOG.md).

## Files

```
rtl/alu.sv          synthesisable RTL
tb/tb_alu.sv        SystemVerilog testbench
cocotb/test_alu.py  cocotb regression
docs/index.rst      full documentation
scripts/alu.sdc     timing constraints
```

Full documentation: [`docs/index.rst`](docs/index.rst).
