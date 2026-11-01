# divider

Sequential restoring divider producing quotient and remainder, signed or
unsigned, with ready/valid interfaces.

Division is the one basic arithmetic operation with no cheap combinational
form. A single-cycle divider is an enormous amount of logic and sets the clock
period for the whole design, so this block is sequential: it produces one
quotient bit per cycle. That is the trade every practical divider makes.

| | |
|---|---|
| **Category** | `arithmetic` |
| **Top module** | `divider` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | `WIDTH + 2` cycles; 2 for division by zero and most-negative / −1 |
| **Throughput** | one division per `WIDTH + 2` cycles; not pipelined |
| **Verified at** | `WIDTH=16 SIGNED=1` |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Rising-edge clock |
| `rst_n` | in | 1 | Active-low reset |
| `s_valid` | in | 1 | Operands are valid |
| `s_ready` | out | 1 | The divider is idle and accepts operands |
| `dividend` | in | `WIDTH` | Dividend |
| `divisor` | in | `WIDTH` | Divisor |
| `m_valid` | out | 1 | Result is valid |
| `m_ready` | in | 1 | Sink accepts the result |
| `quotient` | out | `WIDTH` | Quotient |
| `remainder` | out | `WIDTH` | Remainder |
| `div_by_zero` | out | 1 | The divisor was zero |
| `overflow` | out | 1 | most-negative / −1: the quotient is not representable |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `WIDTH` | `int unsigned` | 32 | >= 2 | Operand width; also the iteration count |
| `SIGNED` | `int unsigned` | 0 | 0 or 1 | Interpret operands as two's complement |

## Conventions

**Rounding.** Truncated, as in C and SystemVerilog: the quotient rounds
towards zero and the remainder takes the sign of the **dividend**. So −7 / 2
is −3 remainder −1, not −4 remainder 1. The identity
`dividend == quotient * divisor + remainder` holds either way; only the
rounding direction differs.

**Division by zero** completes in one step rather than stalling, raises
`div_by_zero`, and returns an all-ones quotient with the dividend as the
remainder — what most processors do.

**most-negative / −1** has no correct answer, because the true quotient's
magnitude is not representable. It raises `overflow` and returns the wrapped
value (most-negative, remainder zero) rather than letting the wrap pass
silently.

## Algorithm

Restoring shift-subtract — school long division, in binary:

```
{remainder, quotient} <<= 1
if (remainder >= divisor) { remainder -= divisor; quotient[0] = 1; }
```

The comparison and the subtraction share one adder: the subtraction's top bit
*is* the comparison. That shortcut is valid only because of the algorithm's
invariant, `remainder < divisor`, which is also why the stored remainder needs
only `WIDTH` bits while the trial subtraction needs `WIDTH + 1`. Signed
division runs on magnitudes and applies the signs afterwards, because the
recurrence is only valid for non-negative values.

## Quick start

```systemverilog
divider #(
  .WIDTH  (32),
  .SIGNED (1)
) u_div (
  .clk         (clk),
  .rst_n       (rst_n),
  .s_valid     (div_req),
  .s_ready     (div_ready),
  .dividend    (rs1_value),
  .divisor     (rs2_value),
  .m_valid     (div_done),
  .m_ready     (writeback_ready),
  .quotient    (quotient),
  .remainder   (remainder),
  .div_by_zero (div_by_zero),
  .overflow    (div_overflow)
);
```

## Verification

```bash
ctest --test-dir build -R 'divider'
```

- `cocotb/test_divider.py` — exact division, division with a remainder,
  division by one, dividing zero, division by zero, the signed overflow case,
  corner-biased randomised operands against Python arithmetic adjusted to the
  truncated convention, an exhaustive sweep at narrow widths, back-to-back
  requests and the division identity.
- `tb/tb_divider.sv` — portable self-checking smoke test against
  SystemVerilog's own `/` and `%`, including a result held through a stalled
  `m_ready`.

## Files

```
rtl/divider.sv          synthesisable RTL
tb/tb_divider.sv        SystemVerilog testbench
cocotb/test_divider.py  cocotb regression
docs/index.rst          full documentation
scripts/divider.sdc     timing constraints
```

Full documentation: [`docs/index.rst`](docs/index.rst).
