# Zynq UltraScale+ reference design

Packages [`cnn_accel`](../../ip/ml/cnn_accel) as an IP integrator core and
builds a design that connects it to the processing system through an AXI DMA,
so a bare-metal Cortex-A53 can drive it.

```
package_ip.tcl          package the RTL as an IP-XACT core
create_project.tcl      build the block design, optionally implement and export
constraints/            implementation constraints and the notes behind them
```

## Build

```bash
vivado -mode batch -source package_ip.tcl
vivado -mode batch -source create_project.tcl -tclargs -board zcu104 -run
```

The first produces `ip_repo/cnn_accel`. The second builds
`build/zcu104/cnn_accel_zcu104`, and with `-run` implements it, prints timing
and utilisation, and writes the XSA that Vitis needs.

Then generate a standalone BSP for the `psu_cortexa53_0` domain and build the
demonstration:

```bash
make -C ../../sw/cnn_accel app BSP=<workspace>/.../bsp/psu_cortexa53_0
```

Boards: `zcu104` (default, XCZU7EV), `zcu102`, `zcu106`, `kv260`. Other
options: `-array_n`, `-clock_mhz`, `-jobs`.

> **Status.** These scripts are written to the documented Vivado 2023.2+ flow
> and are structured the way the tool expects, but they have not been run — no
> Vivado installation was available while they were written. Treat the first
> run as bring-up: the parts most likely to need adjustment are the board
> preset names, which change between Vivado releases, and the
> `apply_bd_automation` argument lists, which are version-sensitive. The RTL
> and the driver are separately verified; see below.

## The design

```
+-------------------+        +------------+       +--------------+
| zynq_ultra_ps_e   |        |  axi_dma   |       |  cnn_accel   |
|                   | HPM0   |            | MM2S  |              |
|   M_AXI_HPM0_LPD  |------->| S_AXI_LITE |------>| s_axis       |
|                   |        |            |       |              |
|   S_AXI_HP0_FPD   |<-------| M_AXI_*    |  S2MM |              |
|                   |        |            |<------| m_axis       |
|   pl_clk0 250 MHz |------->|            |       |              |
+-------------------+        +------------+       +--------------+
```

The accelerator has no control interface. The only thing the processor
configures is the DMA; every accelerator command travels as a frame on the
stream.

**One clock domain.** The DMA and the accelerator both run off `pl_clk0`. A
crossing between them would need an asynchronous FIFO on each stream and would
buy nothing — the accelerator's period is set by a DSP block's
multiply-accumulate, which is comfortable at 250 MHz on a -2 part, and so is
the DMA. If a target part cannot make the frequency, lower the PL clock rather
than splitting the domains.

**128-bit stream.** That is `ARRAY_N * 8` — one int8 lane per array column —
and it is also the width of an HP port, so the DMA delivers one activation
vector per cycle with no packing. That match is what lets the array run at full
rate straight out of DDR.

**Simple-mode DMA.** No scatter-gather, and no data realignment engine: one
transfer is one frame, and buffers are 64-byte aligned by the driver, which is
comfortably more than the 16 bytes an un-DRE'd 128-bit stream requires. See the
[driver README](../../sw/cnn_accel/README.md#scatter-gather) for what moving to
descriptor chains would involve — it is a change to the driver only.

## Packaging notes

Two things in `package_ip.tcl` are worth knowing about, because both are places
where the automatic answer is wrong:

**Reset polarity.** The accelerator's reset is `rst_n`, active low. Inference
packages a reset as active high by default, and an active-low reset packaged
that way is held asserted by a correctly connected `proc_sys_reset` — the
design never leaves reset and nothing indicates why. The script sets
`POLARITY ACTIVE_LOW` explicitly.

**Stream width is derived.** `ARRAY_N` is exposed as a parameter but the
interface width follows from it, so the script restricts it to values that give
a legal AXI4-Stream width. Offering `ARRAY_N = 20` would let a user build a
160-bit stream that no infrastructure IP will connect to.

The RTL is unmodified portfolio RTL — no vendor primitives, no vendor
attributes. Packaging is only a matter of telling IP integrator which ports
form which interface.

## What to check on the first implementation

**DSP count.** Expect `ARRAY_N**2` for the array — 256 at the default size —
plus roughly two per requantiser. Substantially fewer means some
multiply-accumulates were built out of fabric, which costs about a factor of
three in achievable period and no amount of constraining recovers it.

```tcl
report_utilization -cells [get_cells -hierarchical -filter {NAME =~ "*cnn_accel_0*"}]
```

**Expected size**, from the structure rather than from a run: about 24 400
flip-flops, ~290 DSP blocks and ~9 block RAMs. On a ZU7EV that is under a sixth
of the DSPs. On a ZU3EG the 256-DSP array is most of the device's 360, so an
`ARRAY_N` of 8 is the sensible size there.

**Timing.** `constraints/cnn_accel.xdc` lists what to look at, in order, if
250 MHz does not close — the DSP inference first, then `s_axis_tready`, then
the accumulator write path, and only then the clock frequency.

**Floorplanning** is deliberately not constrained at 16x16: the array's wiring
is entirely nearest-neighbour and the placer handles it well when it has room.
At 32x32 and above it needs a pblock shaped like the array; the XDC carries the
reasoning and a worked example.

## Verification status

| Layer | How it is verified | Ran here |
|---|---|---|
| RTL | Verilator lint, cocotb regression, self-checking SV testbench | yes |
| Driver arithmetic and tiling | host self-test against a reference implementation | yes |
| Frame layout | cocotb regression drives the real design | yes |
| Vivado packaging and block design | first run on the tool | no |
| Timing closure at 250 MHz | implementation run | no |

The accelerator's behaviour is verified in simulation; the numbers in this
document that come from simulation say so, and the ones that come from counting
the structure say that too. Nothing here has been run on silicon.
