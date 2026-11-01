# nco — numerically controlled oscillator

An integration example: a quadrature (cos, sin) oscillator built from
[`accumulator`](../../ip/arithmetic/accumulator) and
[`cordic`](../../ip/arithmetic/cordic). It is the local oscillator of a digital
down-converter, which makes it the first building block of an SDR receive
chain.

```
               +-------------+   phase    +-------+  folded   +--------+   +---------+
 freq_word ===>| accumulator |==========> | fold  |=========> | cordic |==>| unfold  |==> cos_out
               | (wrapping)  |            | pi/2  |  phase    |rotation|   | negate  |==> sin_out
               +-------------+            +-------+           +--------+   +---------+
                     ^ enable = cordic accepts   |  fold_q (registered per operation)  ^
                     +---------------------------+-------------------------------------+
```

## Why the composition is this simple

The accumulator wraps at 2^`WIDTH`, so an unsigned phase of 2^`WIDTH` is a
full turn. Read as signed, the same bit pattern is exactly the CORDIC's angle
format — π is 2^(`WIDTH`−1) and the range is [−π, π). The accumulator's
wrap-around *is* the angle's wrap-around, and nothing converts between the two
blocks. That is why the CORDIC's angle format is scaled by π.

## Quadrant folding

The CORDIC converges only for |z| ≲ 0.55π. A phase outside [−π/2, π/2) — its
top two bits differ — is moved by π, which in this format is a flip of the top
bit, and both outputs are negated:

```
cos(t) = -cos(t - pi)        sin(t) = -sin(t - pi)
```

The fold decision is registered when the CORDIC accepts a phase and applied
when the result comes out, because the CORDIC is iterative and the accumulator
has moved on in between.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk`, `rst_n` | in | 1 | Clock and active-low reset |
| `freq_word` | in | `WIDTH` | Phase step per sample; 2^`WIDTH` is one turn, negative rotates backwards |
| `m_valid` / `m_ready` | out / in | 1 | Output stream handshake |
| `cos_out`, `sin_out` | out | `WIDTH` | Samples, signed Q(`WIDTH`−2), amplitude 1.0 |

Output frequency = `freq_word / 2^WIDTH` cycles per sample; one sample every
`ITERATIONS + 2` clocks.

## Verification

```bash
ctest --test-dir build -R 'nco'
```

`cocotb/test_nco.py` targets the glue rather than the blocks: the first
sample, the four cardinal points (three reached only through the fold), DC,
random frequencies in both directions, phases stepping one LSB across every
quadrant boundary, unit radius over a full turn, phase continuity across a
frequency change, and back-pressure — where the fold flag's lifetime matters.
