/*=============================================================================
 * cnn_accel_conv2d.h - a quantised convolution layer on the accelerator
 *
 * The accelerator multiplies matrices. A convolution becomes a matrix multiply
 * by im2col: each output position's receptive field is flattened into one
 * vector of kernel_h*kernel_w*in_c values, and the layer's weights become a
 * matrix of that many rows by out_c columns. This file does the lowering, the
 * tiling and the quantisation preparation.
 *
 * Tensor layouts
 *   input    [in_h][in_w][in_c]                 int8, NHWC
 *   weights  [out_c][kernel_h][kernel_w][in_c]  int8, OHWI - the layout a
 *                                               TFLite quantised model uses
 *   output   [out_h][out_w][out_c]              int8, NHWC
 *   bias     [out_c]                            int32, before zero-point
 *                                               folding
 *   scale    [out_c]                            double, (s_in * s_w) / s_out
 *
 * Copyright (c) 2026 SoC IP Portfolio Contributors
 * SPDX-License-Identifier: Apache-2.0
 *=============================================================================
 */
#ifndef CNN_ACCEL_CONV2D_H
#define CNN_ACCEL_CONV2D_H

#include <stdint.h>

#include "cnn_accel.h"
#include "cnn_accel_quant.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cnn_conv2d_layer {
    unsigned in_h, in_w, in_c;
    unsigned out_h, out_w, out_c;
    unsigned kernel_h, kernel_w;
    unsigned stride_h, stride_w;
    unsigned pad_h, pad_w;

    int8_t   input_zero_point;
    int8_t   output_zero_point;
    int      fused_relu;
} cnn_conv2d_layer;

/*---------------------------------------------------------------------------
 * Workspace.
 *
 * Statically sized and caller-owned: a bare-metal driver that allocates is a
 * driver that can fail in the middle of a layer. Every buffer handed to the
 * DMA is cache-line aligned, which is a correctness requirement rather than a
 * performance one - invalidating a partial line either discards a neighbour's
 * value or keeps a stale copy of a result.
 *-------------------------------------------------------------------------*/
typedef struct cnn_conv2d_workspace {
    uint8_t frame[(CNN_ACCEL_ACC_DEPTH + 1) * CNN_ACCEL_BEAT_BYTES]
        CNN_ACCEL_ALIGNED;
    int8_t  tile[CNN_ACCEL_ARRAY_N * CNN_ACCEL_ARRAY_N] CNN_ACCEL_ALIGNED;
    int8_t  vectors[CNN_ACCEL_ACC_DEPTH * CNN_ACCEL_BEAT_BYTES]
        CNN_ACCEL_ALIGNED;
    int8_t  results[CNN_ACCEL_ACC_DEPTH * CNN_ACCEL_BEAT_BYTES]
        CNN_ACCEL_ALIGNED;
    cnn_accel_channel channels[CNN_ACCEL_ARRAY_N];
} cnn_conv2d_workspace;

/*---------------------------------------------------------------------------
 * cnn_conv2d_output_size
 *
 * The usual floor((in + 2*pad - kernel) / stride) + 1, provided so a caller
 * sizes its output tensor the same way this code will index it.
 *-------------------------------------------------------------------------*/
unsigned cnn_conv2d_output_size(unsigned in, unsigned kernel, unsigned stride,
                                unsigned pad);

/*---------------------------------------------------------------------------
 * cnn_conv2d_run
 *
 * Runs the whole layer. Returns CNN_ACCEL_OK, or the first error encountered -
 * a scale that cannot be represented, a transport failure, or a geometry that
 * does not describe a real convolution.
 *-------------------------------------------------------------------------*/
int cnn_conv2d_run(cnn_accel *dev, const cnn_conv2d_layer *layer,
                   const int8_t *input, const int8_t *weights,
                   const int32_t *bias, const double *scale,
                   int8_t *output, cnn_conv2d_workspace *work);

/*---------------------------------------------------------------------------
 * cnn_conv2d_reference
 *
 * The same layer computed in plain C, with arithmetic identical to the
 * hardware's. Used by the demo to check the accelerator, and by the host self
 * test to check both against each other.
 *-------------------------------------------------------------------------*/
int cnn_conv2d_reference(const cnn_conv2d_layer *layer, const int8_t *input,
                         const int8_t *weights, const int32_t *bias,
                         const double *scale, int8_t *output);

#ifdef __cplusplus
}
#endif

#endif /* CNN_ACCEL_CONV2D_H */
