# cordic

Iterative CORDIC in circular coordinates: rotation mode (sine and cosine) and
vectoring mode (magnitude and arctangent).

CORDIC computes trigonometric functions using only additions, subtractions and
shifts — no multiplier and no lookup table of function values. That is why it
survives: on a device with no spare DSP slices it is often the only way to get
a sine at all, and its cost is almost independent of which function is being
computed. It is also the building block for the NCOs, mixers and
phase/magnitude detectors of a digital radio front end.

| | |
|---|---|
| **Category** | `arithmetic` |
| **Top module** | `cordic` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | `ITERATIONS + 2` cycles |
| **Throughput** | one operation per `ITERATIONS + 2` cycles; not pipelined |
| **Verified at** | `WIDTH=16 ITERATIONS=16` |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Rising-edge clock |
| `rst_n` | in | 1 | Active-low reset |
| `s_valid` | in | 1 | Operands are valid |
| `s_ready` | out | 1 | The block is idle and accepts operands |
| `mode_vectoring` | in | 1 | 0 = rotation, 1 = vectoring |
| `x_in`, `y_in` | in | `WIDTH` | Input vector, signed Q(`WIDTH`−2) |
| `z_in` | in | `WIDTH` | Input angle, signed, π = 2^(`WIDTH`−1) |
| `m_valid` | out | 1 | Result is valid |
| `m_ready` | in | 1 | Sink accepts the result |
| `x_out`, `y_out`, `z_out` | out | `WIDTH` | Result, same formats |
| `out_of_range` | out | 1 | Rotation angle outside the convergence range |

## Modes

| Mode | Inputs | Outputs |
|---|---|---|
| rotation | (x, y, z) | (K·(x cos z − y sin z), K·(x sin z + y cos z), ≈0) |
| vectoring | (x, y, z) | (K·√(x²+y²), ≈0, z + atan(y/x)) |

Rotation from (1/K, 0, θ) yields (cos θ, sin θ). Vectoring from (x, y, 0)
yields the magnitude (times K) and the angle of the vector.

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `WIDTH` | `int unsigned` | 16 | 8 – 32 | Data and angle width |
| `ITERATIONS` | `int unsigned` | 16 | 2 – 32 | Rotation steps; about one bit of accuracy each |

## Number formats

- **Data** — signed Q(`WIDTH`−2): 1.0 is 2^(`WIDTH`−2), range [−2, 2).
- **Angle** — signed, scaled by π: π is 2^(`WIDTH`−1), so the angle covers
  [−π, π) across the full signed range. This makes the arctangent table exact
  at every width: one canonical table at 31 fractional bits is shifted down at
  elaboration rather than regenerated per width.

## The gain

Every CORDIC rotation lengthens the vector, so the result is scaled by
K ≈ 1.6467602581. **This block does not divide it out**, because the right
correction depends on the caller: a sine generator folds 1/K into its starting
amplitude for free, while a magnitude computation needs a real multiply.

1/K = 0.6072529350 = `32'd1304065748` at 31 fractional bits.

## Convergence

- **Rotation** converges for |z| ≤ ~1.7433 rad, a little beyond π/2. Fold
  larger angles into the first or fourth quadrant first and correct the sign
  afterwards. Out-of-range angles raise `out_of_range` rather than returning a
  quietly wrong answer.
- **Vectoring** converges for x > 0 — the right half plane. It is **not**
  flagged: negate the vector and add π to the angle for x < 0.

## Quick start

```systemverilog
// cos and sin of `phase`, unit amplitude.
cordic #(
  .WIDTH      (16),
  .ITERATIONS (16)
) u_cordic (
  .clk            (clk),
  .rst_n          (rst_n),
  .s_valid        (phase_valid),
  .s_ready        (cordic_ready),
  .mode_vectoring (1'b0),
  .x_in           (16'sd9949),     // round(2**14 / K)
  .y_in           (16'sd0),
  .z_in           (phase),
  .m_valid        (iq_valid),
  .m_ready        (1'b1),
  .x_out          (cos_out),
  .y_out          (sin_out),
  .z_out          (),
  .out_of_range   (phase_error)
);
```

## Verification

```bash
ctest --test-dir build -R 'cordic'
```

- `cocotb/test_cordic.py` — sine and cosine at the cardinal angles, magnitude
  and arctangent of known vectors, the convergence flag, random angles and
  vectors against `math.sin`, `math.cos`, `math.hypot` and `math.atan2`,
  accuracy scaling with `ITERATIONS`, and back-to-back operations.
- `tb/tb_cordic.sv` — portable self-checking smoke test against the
  simulator's real-valued `$sin`, `$cos`, `$atan2` and `$sqrt`.

Both compare against an absolute error bound in LSBs rather than demanding an
exact match: CORDIC is an approximation that rounds at every step.

## Files

```
rtl/cordic.sv          synthesisable RTL
tb/tb_cordic.sv        SystemVerilog testbench
cocotb/test_cordic.py  cocotb regression
docs/index.rst         full documentation
scripts/cordic.sdc     timing constraints
```

Full documentation: [`docs/index.rst`](docs/index.rst).
