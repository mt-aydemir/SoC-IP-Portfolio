/*=============================================================================
 * cnn_accel_quant.c - quantisation arithmetic shared with the hardware
 *
 * Copyright (c) 2026 SoC IP Portfolio Contributors
 * SPDX-License-Identifier: Apache-2.0
 *=============================================================================
 */
#include "cnn_accel_quant.h"

#include <math.h>

int cnn_quant_scale(double scale, uint32_t *mult, uint8_t *shift)
{
    int exponent = 0;
    double normalised;
    double scaled;
    int64_t rounded;
    int total_shift;

    if (mult == NULL || shift == NULL) {
        return CNN_ACCEL_ERR_ARG;
    }
    if (!(scale > 0.0) || !isfinite(scale)) {
        return CNN_ACCEL_ERR_ARG;
    }

    /* frexp splits the scale into a mantissa in [0.5, 1) and a power of two,
     * which is exactly the normalisation wanted: the mantissa scaled by
     * 2**MULT_BITS lands in the top octave of the multiplier's range. */
    normalised = frexp(scale, &exponent);
    scaled     = normalised * (double)(1u << CNN_ACCEL_MULT_BITS);
    rounded    = (int64_t)llround(scaled);

    /* Rounding a mantissa of just under 1.0 can carry into the bit above the
     * field. Halving it and lending the bit to the shift is exact. */
    if (rounded > (int64_t)CNN_ACCEL_MULT_MAX) {
        rounded >>= 1;
        exponent += 1;
    }
    if (rounded <= 0) {
        return CNN_ACCEL_ERR_ARG;
    }

    total_shift = (int)CNN_ACCEL_MULT_BITS - exponent;
    if (total_shift < 0 || total_shift > (int)CNN_ACCEL_SHIFT_MAX) {
        /* The representable band is 2**-40 up to 2**24: below it the shift
         * field overflows, above it the shift would have to be negative.
         * Either way the layer's scales are not what a quantised int8 network
         * produces, and clamping silently would turn a preparation mistake
         * into wrong numbers rather than into an error. */
        return CNN_ACCEL_ERR_ARG;
    }

    *mult  = (uint32_t)rounded;
    *shift = (uint8_t)total_shift;
    return CNN_ACCEL_OK;
}

int32_t cnn_quant_fold_zero_point(const int8_t *column, unsigned count,
                                  size_t stride, int8_t input_zero_point,
                                  int32_t bias)
{
    int32_t column_sum = 0;

    for (unsigned k = 0; k < count; k++) {
        column_sum += (int32_t)column[(size_t)k * stride];
    }

    return bias - (int32_t)input_zero_point * column_sum;
}

int8_t cnn_quant_requantise(int32_t acc, const cnn_accel_channel *channel,
                            const cnn_accel_output_format *format)
{
    int64_t product;
    int64_t adjust = 0;
    int64_t value;
    int64_t divisor;

    product = ((int64_t)acc + (int64_t)channel->bias) * (int64_t)channel->mult;

    if (channel->shift != 0u) {
        const int64_t half = (int64_t)1 << (channel->shift - 1u);
        /* Adding `half` before a floor divide rounds half up, which is right
         * for positive values and one out at the ties of negative ones.
         * `half - 1` moves those ties away from zero, matching the hardware. */
        adjust = (product < 0) ? (half - 1) : half;
    }

    /* Written as a divide with an explicit floor rather than as >>, so the
     * result does not depend on the implementation-defined behaviour of a
     * right shift on a negative signed value. */
    divisor = (int64_t)1 << channel->shift;
    value   = product + adjust;
    if (value >= 0) {
        value /= divisor;
    } else {
        value = -(((-value) + divisor - 1) / divisor);
    }

    value += (int64_t)format->zero_point;

    if (value < (int64_t)format->min) {
        return format->min;
    }
    if (value > (int64_t)format->max) {
        return format->max;
    }
    return (int8_t)value;
}

int cnn_quant_prepare_channel(cnn_accel_channel *out, double scale,
                              int32_t bias, const int8_t *column,
                              unsigned count, size_t stride,
                              int8_t input_zero_point)
{
    int status;

    if (out == NULL || column == NULL) {
        return CNN_ACCEL_ERR_ARG;
    }

    status = cnn_quant_scale(scale, &out->mult, &out->shift);
    if (status != CNN_ACCEL_OK) {
        return status;
    }

    out->bias = cnn_quant_fold_zero_point(column, count, stride,
                                          input_zero_point, bias);
    return CNN_ACCEL_OK;
}

void cnn_quant_relu_format(cnn_accel_output_format *format,
                           int8_t output_zero_point, int relu)
{
    format->zero_point = output_zero_point;
    format->min        = relu ? output_zero_point : (int8_t)-128;
    format->max        = (int8_t)127;
}
