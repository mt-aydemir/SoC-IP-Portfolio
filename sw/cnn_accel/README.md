# cnn_accel — bare-metal Cortex-A53 driver

Driver, quantisation preparation and convolution lowering for the
[`cnn_accel`](../../ip/ml/cnn_accel) accelerator, plus a self-checking
demonstration for a Zynq UltraScale+ processing system.

```
include/  cnn_accel.h          frame format and the device API
          cnn_accel_quant.h    scale derivation, zero-point folding, requantise
          cnn_accel_conv2d.h   a convolution layer, lowered and tiled
          cnn_accel_dma.h      AXI DMA transport (Vitis BSP only)
src/      the implementations
app/      main.c — the bare-metal demonstration
test/     a software model of the accelerator, and a host self-test
```

## Quick start

```bash
make test
```

Builds with the system compiler and runs 173 checks in about a second — no
board, no Xilinx headers. This is the target to run after changing anything.

```bash
make app BSP=/path/to/vitis/workspace/.../bsp/psu_cortexa53_0
```

Cross-compiles the demonstration against a Vitis standalone BSP for the
hardware design in [`fpga/zynq_ultrascale`](../../fpga/zynq_ultrascale).

## How the accelerator is driven

It has **no register interface**. Every command is a TLAST-delimited frame on
its AXI4-Stream sink, so the driver is a frame builder and a DMA:

```c
cnn_accel_dma_open(&dma, XPAR_AXIDMA_0_DEVICE_ID);
cnn_accel_dma_bind(&transport, &dma);
cnn_accel_open(&device, &transport, frame_buffer, sizeof(frame_buffer));
cnn_accel_check_geometry(&device);          /* the bitstream is what we think */

cnn_accel_load_weights(&device, tile);      /* ARRAY_N x ARRAY_N int8 */
cnn_accel_load_params(&device, channels, &format);
cnn_accel_compute(&device, vectors, count, CNN_ACCEL_ONLY_TILE, results);
```

One DMA transfer is one frame, because simple-mode DMA asserts `TLAST` at the
end of a transfer and that is exactly how the accelerator delimits a command.

Or, for a whole convolution layer:

```c
cnn_conv2d_run(&device, &layer, input, weights, bias, scale, output, &work);
```

## The three things that are easy to get wrong

**Zero-point folding.** The array computes `sum w*a` with both operands signed.
An asymmetrically quantised activation means `sum w*(a - z)`, and the
difference is `-z * sum w` — a constant per output channel. Folding it into the
bias once, when the layer is prepared, removes a subtraction from all 256
multipliers. `cnn_quant_fold_zero_point()` does it; the host test proves the
identity holds.

It is also why zero padding writes the **input zero point**, not integer zero:
a padded position holds the quantised representation of 0.0, and the folded
bias already subtracts the zero point from every term.

**Scale normalisation.** A scale of `2^-20` written as `mult=1, shift=20` has
one significant bit; the same number as `mult=0x800000, shift=43` has
twenty-four. `cnn_quant_scale()` normalises into the top octave via `frexp`,
and refuses scales outside the representable band rather than clamping them —
clamping would turn a preparation mistake into wrong numbers instead of an
error.

**Cache maintenance.** The A53's data cache is write-back and the DMA is not
coherent with it on the HP ports. Flush before a transmit; invalidate before
**and** after a receive. The invalidate *before* matters as much as the one
after — a dirty line sitting over the destination buffer would otherwise be
written back on top of the DMA's data at an unpredictable later moment, and the
corruption looks like a hardware fault. Every DMA buffer is therefore
cache-line aligned and a whole number of lines long; a partial-line invalidate
either discards a neighbour's value or leaves part of a result stale.

## Loop order in `cnn_conv2d_run`

```
output channel tile  (ARRAY_N channels)
  output position tile  (up to ACC_DEPTH positions)
    reduction tile        (ARRAY_N terms)
```

The reduction is innermost because its tiles share the accelerator's
accumulator buffer — they must run consecutively with `first` on the first and
`last` on the last. The channel tile is outermost because the requantisation
parameters are per channel and loading them costs a frame.

The cost is that the im2col vectors are rebuilt per channel tile. That is
`out_c/ARRAY_N` passes over `positions*reduction` bytes against an accelerator
doing `positions*reduction*out_c` multiply-accumulates, so the ratio is
`ARRAY_N` to one in the accelerator's favour. A layer with many output channels
and a shallow reduction would prefer the im2col matrix cached for the whole
position tile, at the cost of a workspace that grows with the reduction depth.

## Transport abstraction, and what the host test proves

The transport is two pairs of function pointers rather than direct DMA calls,
so the same driver runs against hardware and against a software model of the
RTL. That is what lets `make test` exercise the lowering, the tiling and the
quantisation on a development machine.

Be clear about what that proves. The host test checks the driver's arithmetic
against an independent reference implementation of the same convolution, over
six layer geometries including ragged tile tails, strides, padding with a
non-zero zero point and a fused ReLU. It does **not** independently confirm the
frame byte layout, because the model and the driver were written from the same
reading of the RTL. The authority on the layout is
[`test_cnn_accel.py`](../../ip/ml/cnn_accel/cocotb/test_cnn_accel.py), which
drives the real design.

## Scatter-gather

The architectural argument for putting commands in the stream is that a whole
layer becomes one descriptor chain: the DMA walks it to completion and the
processor is untouched between tiles. This driver uses **simple mode**, which
does not do that — it is one transfer per frame, with the processor issuing
each one.

That is a deliberate scoping choice, not an oversight. Simple mode works
against every `axi_dma` configuration, needs no BD ring in uncached memory, and
is the right thing to bring a design up with. Moving to scatter-gather is a
change to this file only: build the frames for a whole layer end to end in one
buffer — `cnn_conv2d_run` already emits them in order — and hand the DMA one
descriptor per frame, `TLAST` set on the last descriptor of each. The
accelerator needs no change at all, which is the point.

## API summary

| Function | Purpose |
|---|---|
| `cnn_accel_open` | Bind a transport and a frame staging buffer |
| `cnn_accel_check_geometry` | Refuse to run against the wrong bitstream |
| `cnn_accel_load_weights` | Publish an `ARRAY_N x ARRAY_N` int8 tile |
| `cnn_accel_load_params` | Per-channel bias, multiplier, shift; clamp window |
| `cnn_accel_compute` | One tile, with first/last accumulation flags |
| `cnn_accel_status_read` | Geometry, sticky flags and counters |
| `cnn_accel_nop` | Fence, and clear the sticky error |
| `cnn_quant_scale` | Real scale to fixed-point multiplier and shift |
| `cnn_quant_fold_zero_point` | Input zero point into the bias |
| `cnn_quant_requantise` | Bit-exact with `requant_int8` |
| `cnn_conv2d_run` | A whole convolution layer |
| `cnn_conv2d_reference` | The same layer in plain C, for checking |

## Tensor layouts

| Tensor | Layout |
|---|---|
| input | `[in_h][in_w][in_c]` int8, NHWC |
| weights | `[out_c][kernel_h][kernel_w][in_c]` int8, OHWI — TFLite's layout |
| output | `[out_h][out_w][out_c]` int8, NHWC |
| bias | `[out_c]` int32, before zero-point folding |
| scale | `[out_c]` double, `(s_in * s_w) / s_out` |
