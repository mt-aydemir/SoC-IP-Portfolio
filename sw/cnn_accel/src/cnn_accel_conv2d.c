/*=============================================================================
 * cnn_accel_conv2d.c - lowering, tiling and quantisation for one conv layer
 *
 * THE THREE LOOPS, AND WHY THEY NEST THIS WAY
 *
 *   output channel tile   (ARRAY_N channels at a time)
 *     output position tile  (up to ACC_DEPTH positions at a time)
 *       reduction tile        (ARRAY_N terms at a time)
 *
 *   The reduction is innermost because its tiles share the accelerator's
 *   accumulator buffer: they must run consecutively, with `first` on the
 *   first and `last` on the last, or a partial sum would be added to the
 *   wrong output position.
 *
 *   The output channel tile is outermost because the requantisation
 *   parameters are per channel, and loading them costs a frame. Putting it
 *   inside would reload them for every position tile.
 *
 *   The cost of that ordering is that the im2col vectors are rebuilt for each
 *   output channel tile rather than built once. It is the right trade at these
 *   sizes - the rebuild is out_c/ARRAY_N passes over positions*reduction
 *   bytes, against an accelerator doing positions*reduction*out_c
 *   multiply-accumulates, so the ratio is ARRAY_N to one in the
 *   accelerator's favour. A layer with many output channels and a shallow
 *   reduction would want the im2col matrix cached for the whole position tile
 *   instead, at the cost of a workspace that grows with the reduction depth.
 *
 * PADDING
 *   A padded input position holds the quantised representation of zero, which
 *   is the input zero point rather than the integer zero. Feeding the zero
 *   point through is what makes it correct, because the bias already carries
 *   the -z_a * sum(w) correction over every term of the reduction.
 *
 * Copyright (c) 2026 SoC IP Portfolio Contributors
 * SPDX-License-Identifier: Apache-2.0
 *=============================================================================
 */
#include "cnn_accel_conv2d.h"

#include <string.h>

unsigned cnn_conv2d_output_size(unsigned in, unsigned kernel, unsigned stride,
                                unsigned pad)
{
    if (stride == 0u || in + 2u * pad < kernel) {
        return 0u;
    }
    return (in + 2u * pad - kernel) / stride + 1u;
}

/*---------------------------------------------------------------------------
 * Geometry check.
 *
 * Every later loop trusts these, so they are checked once here rather than
 * defended against repeatedly.
 *-------------------------------------------------------------------------*/
static int layer_is_sane(const cnn_conv2d_layer *layer)
{
    if (layer->in_h == 0u || layer->in_w == 0u || layer->in_c == 0u) {
        return 0;
    }
    if (layer->out_c == 0u || layer->kernel_h == 0u || layer->kernel_w == 0u) {
        return 0;
    }
    if (layer->stride_h == 0u || layer->stride_w == 0u) {
        return 0;
    }
    if (layer->out_h != cnn_conv2d_output_size(layer->in_h, layer->kernel_h,
                                               layer->stride_h, layer->pad_h)) {
        return 0;
    }
    if (layer->out_w != cnn_conv2d_output_size(layer->in_w, layer->kernel_w,
                                               layer->stride_w, layer->pad_w)) {
        return 0;
    }
    return 1;
}

static unsigned reduction_depth(const cnn_conv2d_layer *layer)
{
    return layer->kernel_h * layer->kernel_w * layer->in_c;
}

/*---------------------------------------------------------------------------
 * One element of the im2col matrix.
 *
 * Row `r` of the flattened receptive field decomposes as
 * ((ky * kernel_w) + kx) * in_c + ic, which is the same order the weights are
 * stored in - that is what makes the lowering a reindex rather than a
 * transpose.
 *-------------------------------------------------------------------------*/
static int8_t im2col_element(const cnn_conv2d_layer *layer,
                             const int8_t *input, unsigned position,
                             unsigned r)
{
    const unsigned oy = position / layer->out_w;
    const unsigned ox = position % layer->out_w;

    const unsigned ic = r % layer->in_c;
    const unsigned kx = (r / layer->in_c) % layer->kernel_w;
    const unsigned ky = (r / layer->in_c) / layer->kernel_w;

    /* Signed, because the padded region is at negative coordinates. */
    const int iy = (int)(oy * layer->stride_h) - (int)layer->pad_h + (int)ky;
    const int ix = (int)(ox * layer->stride_w) - (int)layer->pad_w + (int)kx;

    if (iy < 0 || ix < 0 || iy >= (int)layer->in_h || ix >= (int)layer->in_w) {
        return layer->input_zero_point;
    }

    return input[(((size_t)iy * layer->in_w) + (size_t)ix) * layer->in_c + ic];
}

/*---------------------------------------------------------------------------
 * Build the ARRAY_N by ARRAY_N weight tile for one (output channel, reduction)
 * pair, padding with zeros where the layer runs out.
 *
 * Padding with zero is exactly right: a zero weight contributes nothing to the
 * column sum, and it also contributes nothing to the zero-point correction,
 * so the tile and the folded bias stay consistent.
 *-------------------------------------------------------------------------*/
static void build_weight_tile(const cnn_conv2d_layer *layer,
                              const int8_t *weights, unsigned channel_base,
                              unsigned reduction_base, int8_t *tile)
{
    const unsigned depth = reduction_depth(layer);

    memset(tile, 0, (size_t)CNN_ACCEL_ARRAY_N * CNN_ACCEL_ARRAY_N);

    for (unsigned k = 0; k < CNN_ACCEL_ARRAY_N; k++) {
        const unsigned r = reduction_base + k;
        if (r >= depth) {
            break;
        }
        for (unsigned m = 0; m < CNN_ACCEL_ARRAY_N; m++) {
            const unsigned oc = channel_base + m;
            if (oc >= layer->out_c) {
                break;
            }
            tile[(size_t)k * CNN_ACCEL_ARRAY_N + m] =
                weights[(size_t)oc * depth + r];
        }
    }
}

/*---------------------------------------------------------------------------
 * Prepare the requantisation parameters for one tile of output channels.
 *
 * The zero-point fold runs over the whole reduction, not over one tile of it,
 * which is why it takes the layer's weight pointer rather than the tile.
 *-------------------------------------------------------------------------*/
static int prepare_channels(const cnn_conv2d_layer *layer,
                            const int8_t *weights, const int32_t *bias,
                            const double *scale, unsigned channel_base,
                            cnn_accel_channel *channels)
{
    const unsigned depth = reduction_depth(layer);

    for (unsigned m = 0; m < CNN_ACCEL_ARRAY_N; m++) {
        const unsigned oc = channel_base + m;

        if (oc >= layer->out_c) {
            /* A channel the layer does not have. Its column of the weight tile
             * is zero, so any parameters produce the output zero point; a zero
             * multiplier says so explicitly. */
            channels[m].bias  = 0;
            channels[m].mult  = 0u;
            channels[m].shift = 0u;
            continue;
        }

        int status = cnn_quant_prepare_channel(
            &channels[m], scale[oc], bias[oc],
            &weights[(size_t)oc * depth], depth, 1u,
            layer->input_zero_point);
        if (status != CNN_ACCEL_OK) {
            return status;
        }
    }

    return CNN_ACCEL_OK;
}

/*---------------------------------------------------------------------------
 * cnn_conv2d_run
 *-------------------------------------------------------------------------*/
int cnn_conv2d_run(cnn_accel *dev, const cnn_conv2d_layer *layer,
                   const int8_t *input, const int8_t *weights,
                   const int32_t *bias, const double *scale,
                   int8_t *output, cnn_conv2d_workspace *work)
{
    cnn_accel_output_format format;
    unsigned depth;
    unsigned positions;
    int status;

    if (dev == NULL || layer == NULL || input == NULL || weights == NULL ||
        bias == NULL || scale == NULL || output == NULL || work == NULL) {
        return CNN_ACCEL_ERR_ARG;
    }
    if (!layer_is_sane(layer)) {
        return CNN_ACCEL_ERR_ARG;
    }

    depth     = reduction_depth(layer);
    positions = layer->out_h * layer->out_w;

    cnn_quant_relu_format(&format, layer->output_zero_point,
                          layer->fused_relu);

    for (unsigned channel_base = 0; channel_base < layer->out_c;
         channel_base += CNN_ACCEL_ARRAY_N) {

        status = prepare_channels(layer, weights, bias, scale, channel_base,
                                  work->channels);
        if (status != CNN_ACCEL_OK) {
            return status;
        }

        status = cnn_accel_load_params(dev, work->channels, &format);
        if (status != CNN_ACCEL_OK) {
            return status;
        }

        for (unsigned position_base = 0; position_base < positions;
             position_base += CNN_ACCEL_ACC_DEPTH) {

            const unsigned remaining = positions - position_base;
            const unsigned chunk = (remaining < CNN_ACCEL_ACC_DEPTH)
                                 ? remaining : CNN_ACCEL_ACC_DEPTH;

            for (unsigned reduction_base = 0; reduction_base < depth;
                 reduction_base += CNN_ACCEL_ARRAY_N) {

                const int first = (reduction_base == 0u);
                const int last  = (reduction_base + CNN_ACCEL_ARRAY_N >= depth);
                unsigned flags  = 0u;

                build_weight_tile(layer, weights, channel_base, reduction_base,
                                  work->tile);
                status = cnn_accel_load_weights(dev, work->tile);
                if (status != CNN_ACCEL_OK) {
                    return status;
                }

                for (unsigned v = 0; v < chunk; v++) {
                    int8_t *vector = &work->vectors[(size_t)v *
                                                    CNN_ACCEL_BEAT_BYTES];
                    for (unsigned k = 0; k < CNN_ACCEL_ARRAY_N; k++) {
                        const unsigned r = reduction_base + k;
                        vector[k] = (r < depth)
                                  ? im2col_element(layer, input,
                                                   position_base + v, r)
                                  : (int8_t)0;
                    }
                }

                if (first) {
                    flags |= CNN_ACCEL_FIRST_TILE;
                }
                if (last) {
                    flags |= CNN_ACCEL_LAST_TILE;
                }

                status = cnn_accel_compute(dev, work->vectors,
                                           (uint16_t)chunk, flags,
                                           last ? work->results : NULL);
                if (status != CNN_ACCEL_OK) {
                    return status;
                }
            }

            /* Scatter the tile's channels back into the NHWC output. */
            for (unsigned v = 0; v < chunk; v++) {
                const size_t out_base =
                    (size_t)(position_base + v) * layer->out_c + channel_base;
                for (unsigned m = 0; m < CNN_ACCEL_ARRAY_N; m++) {
                    if (channel_base + m >= layer->out_c) {
                        break;
                    }
                    output[out_base + m] =
                        work->results[(size_t)v * CNN_ACCEL_BEAT_BYTES + m];
                }
            }
        }
    }

    return CNN_ACCEL_OK;
}

/*---------------------------------------------------------------------------
 * cnn_conv2d_reference
 *
 * Plain C, no accelerator, arithmetic identical to the hardware's. The
 * accumulation order differs - this walks the reduction in one pass while the
 * accelerator splits it into tiles - but integer addition is associative, so
 * the results are equal rather than merely close.
 *-------------------------------------------------------------------------*/
int cnn_conv2d_reference(const cnn_conv2d_layer *layer, const int8_t *input,
                         const int8_t *weights, const int32_t *bias,
                         const double *scale, int8_t *output)
{
    cnn_accel_output_format format;
    unsigned depth;
    unsigned positions;

    if (layer == NULL || input == NULL || weights == NULL || bias == NULL ||
        scale == NULL || output == NULL) {
        return CNN_ACCEL_ERR_ARG;
    }
    if (!layer_is_sane(layer)) {
        return CNN_ACCEL_ERR_ARG;
    }

    depth     = reduction_depth(layer);
    positions = layer->out_h * layer->out_w;

    cnn_quant_relu_format(&format, layer->output_zero_point,
                          layer->fused_relu);

    for (unsigned oc = 0; oc < layer->out_c; oc++) {
        cnn_accel_channel channel;
        int status = cnn_quant_prepare_channel(
            &channel, scale[oc], bias[oc], &weights[(size_t)oc * depth],
            depth, 1u, layer->input_zero_point);
        if (status != CNN_ACCEL_OK) {
            return status;
        }

        for (unsigned position = 0; position < positions; position++) {
            int32_t accumulator = 0;

            for (unsigned r = 0; r < depth; r++) {
                accumulator += (int32_t)weights[(size_t)oc * depth + r] *
                               (int32_t)im2col_element(layer, input, position, r);
            }

            output[(size_t)position * layer->out_c + oc] =
                cnn_quant_requantise(accumulator, &channel, &format);
        }
    }

    return CNN_ACCEL_OK;
}
