# clk_divider

Integer clock divider producing both a divided clock and the equivalent clock
enable.

| | |
|---|---|
| **Category** | `clocking` |
| **Top module** | `clk_divider` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Duty cycle** | exactly 50% for every `DIVISOR >= 2`, odd ratios included |
| **Verified at** | 10.0 ns clock period, `DIVISOR = 5` |
| **Licence** | Apache-2.0 |

## Which output to use

**`clk_en` is the preferred output.** It is a single-cycle enable pulse in the
*source* clock domain, one pulse every `DIVISOR` cycles. The whole design stays
in one clock domain, static timing analysis sees one clock, and no clock tree
resource is consumed.

```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
  if (!rst_n)      counter <= '0;
  else if (clk_en) counter <= counter + 1;   // runs at the divided rate
end
```

**`clk_out` is a real divided clock.** Use it only when a slower clock edge is
genuinely unavoidable — driving an external device, or feeding a block with no
enable input. It is a generated clock and must be declared as such in the SDC.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Source clock |
| `rst_n` | in | 1 | Active-low reset |
| `enable` | in | 1 | Synchronous enable; deasserting parks both outputs |
| `clk_en` | out | 1 | One source cycle wide, once every `DIVISOR` cycles |
| `clk_out` | out | 1 | Divided clock, 50% duty |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DIVISOR` | `int unsigned` | 2 | >= 1 | Division ratio. 1 passes the clock through |

## The odd divisor

A 50% duty cycle at an odd `DIVISOR` is not achievable from the rising edge
alone — the high and low phases would have to differ by one source period. The
odd case therefore combines a rising-edge-generated phase with a
falling-edge-generated one, which shifts the second by half a period and makes
the two halves equal. That costs one negative-edge flip-flop, so the even case,
which does not need it, does not pay for it.

## Quick start

```systemverilog
clk_divider #(.DIVISOR(5)) u_div (
  .clk     (clk_sys),
  .rst_n   (rst_n_sys),
  .enable  (1'b1),
  .clk_en  (tick_10mhz),   // prefer this
  .clk_out (clk_10mhz)     // only if a real clock is needed
);
```

## Constraints

If `clk_out` is used, apply [`scripts/clk_divider.sdc`](scripts/clk_divider.sdc),
which declares the generated clock. Omitting it leaves the divided domain
completely untimed.

## Verification

```bash
ctest --test-dir build -R 'clk_divider'
```

The duty cycle is *measured* from simulation timestamps, not inferred from a
model — that is the only way to catch a phase wrong by half a source period.

- `cocotb/test_clk_divider.py` — parked state, `clk_en` rate, exact 50% duty
  over 12 periods, disable/re-enable, randomised enable toggling, and a
  200-period run checking the divided period accumulates no drift.
- `tb/tb_clk_divider.sv` — portable smoke test measuring high and low phases
  with `$realtime`.

Full documentation: [`docs/index.rst`](docs/index.rst).
