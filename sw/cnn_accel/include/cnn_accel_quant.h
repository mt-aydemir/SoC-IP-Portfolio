/*=============================================================================
 * cnn_accel_quant.h - quantisation arithmetic shared with the hardware
 *
 * Three things live here, and each of them is a place where a quantised
 * network is usually got wrong:
 *
 *   * turning a real rescaling factor into the accelerator's fixed-point
 *     multiplier and shift without throwing away precision,
 *   * folding an asymmetric input zero point into the bias, so the datapath
 *     never has to subtract one, and
 *   * the requantisation itself, bit-exact with requant_int8, so a host-side
 *     reference and the hardware agree to the last bit rather than to within
 *     a tolerance.
 *
 * Copyright (c) 2026 SoC IP Portfolio Contributors
 * SPDX-License-Identifier: Apache-2.0
 *=============================================================================
 */
#ifndef CNN_ACCEL_QUANT_H
#define CNN_ACCEL_QUANT_H

#include <stdint.h>

#include "cnn_accel.h"

#ifdef __cplusplus
extern "C" {
#endif

/*---------------------------------------------------------------------------
 * cnn_quant_scale
 *
 * Express a positive real `scale` as mult / 2**shift.
 *
 * The multiplier is normalised into the top octave of its range, which is what
 * keeps the precision: a scale of 2**-20 represented as mult=1, shift=20 has
 * one significant bit, while the same scale as mult=0x800000, shift=43 has
 * twenty-four. Both are arithmetically the same number; only one of them
 * survives being multiplied by an accumulator.
 *
 * Returns CNN_ACCEL_OK, or CNN_ACCEL_ERR_ARG if the scale cannot be
 * represented - which in practice means it is not positive, or the shift it
 * needs is outside the field the frame format provides.
 *-------------------------------------------------------------------------*/
int cnn_quant_scale(double scale, uint32_t *mult, uint8_t *shift);

/*---------------------------------------------------------------------------
 * cnn_quant_fold_zero_point
 *
 * The accumulator the array produces is sum_k w[k] * a[k], with both operands
 * signed. An asymmetrically quantised activation really means
 * sum_k w[k] * (a[k] - z_a), and the difference is
 *
 *     - z_a * sum_k w[k]
 *
 * which depends only on the weights. Adding it to the bias once, when the
 * layer is prepared, removes a subtraction from all ARRAY_N**2 multipliers.
 *
 * `column` points at the channel's first weight and `stride` is the element
 * stride between successive reduction terms - 1 for a layer's weights laid out
 * per output channel, ARRAY_N for a tile in the accelerator's own order.
 *
 * The sum must run over *every* term of the layer's reduction, not just the
 * terms of one tile. Zero padding in a tile contributes nothing to it, which
 * is what makes the two consistent.
 *-------------------------------------------------------------------------*/
int32_t cnn_quant_fold_zero_point(const int8_t *column, unsigned count,
                                  size_t stride, int8_t input_zero_point,
                                  int32_t bias);

/*---------------------------------------------------------------------------
 * cnn_quant_requantise
 *
 * Bit-exact with requant_int8: round to nearest, ties away from zero, applied
 * once to the full-width product, then the output zero point and the clamp.
 *
 * Two facts make the C safe. The product is at most 33 + 24 bits so it cannot
 * overflow int64_t, and C's >> on a negative signed value is
 * implementation-defined in principle but arithmetic on every compiler this
 * runs on - so the shift is written explicitly as a floor divide instead, and
 * the two agree without depending on that.
 *-------------------------------------------------------------------------*/
int8_t cnn_quant_requantise(int32_t acc, const cnn_accel_channel *channel,
                            const cnn_accel_output_format *format);

/*---------------------------------------------------------------------------
 * cnn_quant_prepare_channel
 *
 * The whole per-channel preparation in one call: derive the fixed-point scale
 * from the real one, and fold the input zero point into the bias.
 *-------------------------------------------------------------------------*/
int cnn_quant_prepare_channel(cnn_accel_channel *out, double scale,
                              int32_t bias, const int8_t *column,
                              unsigned count, size_t stride,
                              int8_t input_zero_point);

/*---------------------------------------------------------------------------
 * cnn_quant_relu_format
 *
 * A fused ReLU is not a mode: it is the clamp window with its floor raised to
 * the output zero point, which is what the quantised value of zero is.
 *-------------------------------------------------------------------------*/
void cnn_quant_relu_format(cnn_accel_output_format *format,
                           int8_t output_zero_point, int relu);

#ifdef __cplusplus
}
#endif

#endif /* CNN_ACCEL_QUANT_H */
