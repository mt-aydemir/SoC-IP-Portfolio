/*=============================================================================
 * test_host.c - host self-test for the cnn_accel driver
 *
 * Runs the driver against a software model of the accelerator and checks it
 * against an independent reference implementation of the same convolution.
 * This is the part of the stack the RTL regression cannot reach: the hardware
 * has never heard of a convolution, so the lowering, the tiling and the
 * quantisation preparation have to be verified here.
 *
 *   cc -std=c11 -Wall -Wextra -I include -I test \
 *      src/cnn_accel.c src/cnn_accel_quant.c src/cnn_accel_conv2d.c \
 *      test/cnn_accel_model.c test/test_host.c -lm -o build/test_host
 *
 * Copyright (c) 2026 SoC IP Portfolio Contributors
 * SPDX-License-Identifier: Apache-2.0
 *=============================================================================
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cnn_accel.h"
#include "cnn_accel_conv2d.h"
#include "cnn_accel_model.h"
#include "cnn_accel_quant.h"

static int failures;
static int checks;

static void check(int condition, const char *what)
{
    checks++;
    if (!condition) {
        failures++;
        printf("  FAIL: %s\n", what);
    }
}

static void check_eq(long got, long want, const char *what)
{
    checks++;
    if (got != want) {
        failures++;
        printf("  FAIL: %s: expected %ld, got %ld\n", what, want, got);
    }
}

/* A small reproducible generator, so a failure can be replayed. */
static uint32_t rng_state = 0x1234567u;

static uint32_t next_random(void)
{
    rng_state = rng_state * 1664525u + 1013904223u;
    return rng_state;
}

static int8_t random_int8(void)
{
    return (int8_t)(next_random() >> 24);
}

/*===========================================================================
 * Quantisation
 *=========================================================================*/
static void test_quant_scale(void)
{
    printf("test_quant_scale\n");

    /* A scale is representable across the band the header format allows, and
     * the round trip has to be accurate to well under an int8 least
     * significant bit or the layer loses accuracy for no reason. */
    static const double scales[] = {
        1.0, 0.5, 0.25, 0.9, 0.123456, 1e-3, 1e-6, 3.0517578125e-05,
        7.62939453125e-06, 2.0, 100.0
    };

    for (size_t i = 0; i < sizeof(scales) / sizeof(scales[0]); i++) {
        uint32_t mult;
        uint8_t shift;
        double reconstructed;
        double relative;

        check_eq(cnn_quant_scale(scales[i], &mult, &shift), CNN_ACCEL_OK,
                 "scale is representable");
        check(mult <= CNN_ACCEL_MULT_MAX, "multiplier fits its field");
        check(shift <= CNN_ACCEL_SHIFT_MAX, "shift fits its field");

        /* Normalised into the top octave: that is what keeps the precision. */
        check(mult > (CNN_ACCEL_MULT_MAX / 2u),
              "multiplier is normalised into the top octave");

        reconstructed = (double)mult / ldexp(1.0, shift);
        relative = fabs(reconstructed - scales[i]) / scales[i];
        check(relative < 1e-6, "scale round trips to better than 1e-6");
    }

    /* Scales outside the representable band are refused rather than clamped. */
    {
        uint32_t mult;
        uint8_t shift;
        check(cnn_quant_scale(0.0, &mult, &shift) != CNN_ACCEL_OK,
              "a zero scale is refused");
        check(cnn_quant_scale(-1.0, &mult, &shift) != CNN_ACCEL_OK,
              "a negative scale is refused");
        check(cnn_quant_scale(1e-30, &mult, &shift) != CNN_ACCEL_OK,
              "a scale below the shift field's reach is refused");
    }
}

static void test_quant_requantise(void)
{
    cnn_accel_channel channel = { 0, 1u, 1u };
    cnn_accel_output_format format = { 0, -128, 127 };

    printf("test_quant_requantise\n");

    /* Round to nearest, ties away from zero - the same identity the RTL
     * implements, checked at the ties of both signs. */
    check_eq(cnn_quant_requantise(3, &channel, &format), 2, "1.5 rounds to 2");
    check_eq(cnn_quant_requantise(-3, &channel, &format), -2,
             "-1.5 rounds to -2");
    check_eq(cnn_quant_requantise(1, &channel, &format), 1, "0.5 rounds to 1");
    check_eq(cnn_quant_requantise(-1, &channel, &format), -1,
             "-0.5 rounds to -1");
    check_eq(cnn_quant_requantise(2, &channel, &format), 1, "1.0 stays 1");
    check_eq(cnn_quant_requantise(-2, &channel, &format), -1,
             "-1.0 stays -1");

    channel.shift = 2u;
    check_eq(cnn_quant_requantise(5, &channel, &format), 1, "1.25 rounds to 1");
    check_eq(cnn_quant_requantise(6, &channel, &format), 2, "1.5 rounds to 2");
    check_eq(cnn_quant_requantise(-6, &channel, &format), -2,
             "-1.5 rounds to -2");
    check_eq(cnn_quant_requantise(-5, &channel, &format), -1,
             "-1.25 rounds to -1");

    /* A shift of zero must add no rounding term, or every negative result is
     * dragged down by one. */
    channel.shift = 0u;
    check_eq(cnn_quant_requantise(-1, &channel, &format), -1,
             "shift of zero is the identity for -1");
    check_eq(cnn_quant_requantise(0, &channel, &format), 0,
             "shift of zero is the identity for 0");

    /* Saturation, not wrap-around. */
    check_eq(cnn_quant_requantise(1000, &channel, &format), 127,
             "clamps at the top");
    check_eq(cnn_quant_requantise(-1000, &channel, &format), -128,
             "clamps at the bottom");

    /* A fused ReLU is the window floor raised to the output zero point. */
    format.zero_point = -5;
    format.min = -5;
    check_eq(cnn_quant_requantise(-1000, &channel, &format), -5,
             "a fused ReLU floors at the zero point");
}

static void test_zero_point_folding(void)
{
    /* sum_k w[k]*(a[k] - z) must equal sum_k w[k]*a[k] + folded_bias. */
    int8_t weights[8];
    int8_t activations[8];
    const int8_t zero_point = 11;
    int32_t direct = 0;
    int32_t folded_bias;
    int32_t raw = 0;

    printf("test_zero_point_folding\n");

    for (unsigned k = 0; k < 8u; k++) {
        weights[k] = random_int8();
        activations[k] = random_int8();
        direct += (int32_t)weights[k] *
                  ((int32_t)activations[k] - (int32_t)zero_point);
        raw += (int32_t)weights[k] * (int32_t)activations[k];
    }

    folded_bias = cnn_quant_fold_zero_point(weights, 8u, 1u, zero_point, 0);
    check_eq(raw + folded_bias, direct,
             "the folded bias reproduces the zero-point subtraction");
}

/*===========================================================================
 * A convolution layer, driver against reference
 *=========================================================================*/
#define MAX_IN_H 10u
#define MAX_IN_W 10u
#define MAX_IN_C 40u
#define MAX_OUT_C 40u
#define MAX_K 3u

static int8_t  input_tensor[MAX_IN_H * MAX_IN_W * MAX_IN_C];
static int8_t  weight_tensor[MAX_OUT_C * MAX_K * MAX_K * MAX_IN_C];
static int32_t bias_tensor[MAX_OUT_C];
static double  scale_tensor[MAX_OUT_C];
static int8_t  output_accel[MAX_IN_H * MAX_IN_W * MAX_OUT_C];
static int8_t  output_reference[MAX_IN_H * MAX_IN_W * MAX_OUT_C];

static cnn_conv2d_workspace workspace;
static uint8_t frame_buffer[(CNN_ACCEL_ACC_DEPTH + 1) * CNN_ACCEL_BEAT_BYTES]
    CNN_ACCEL_ALIGNED;

static void run_layer_case(const char *label, cnn_conv2d_layer layer)
{
    cnn_accel_model model;
    cnn_accel_transport transport;
    cnn_accel device;
    unsigned depth;
    unsigned positions;
    int status;
    int mismatches = 0;

    layer.out_h = cnn_conv2d_output_size(layer.in_h, layer.kernel_h,
                                         layer.stride_h, layer.pad_h);
    layer.out_w = cnn_conv2d_output_size(layer.in_w, layer.kernel_w,
                                         layer.stride_w, layer.pad_w);

    depth     = layer.kernel_h * layer.kernel_w * layer.in_c;
    positions = layer.out_h * layer.out_w;

    printf("%s: %ux%ux%u -> %ux%ux%u, %ux%u kernel, stride %u, pad %u "
           "(reduction %u, positions %u)\n",
           label, layer.in_h, layer.in_w, layer.in_c,
           layer.out_h, layer.out_w, layer.out_c,
           layer.kernel_h, layer.kernel_w, layer.stride_h, layer.pad_h,
           depth, positions);

    for (size_t i = 0; i < (size_t)layer.in_h * layer.in_w * layer.in_c; i++) {
        input_tensor[i] = random_int8();
    }
    for (size_t i = 0; i < (size_t)layer.out_c * depth; i++) {
        weight_tensor[i] = random_int8();
    }
    for (unsigned oc = 0; oc < layer.out_c; oc++) {
        bias_tensor[oc] = (int32_t)(next_random() % 4001u) - 2000;
        /* The scale a real layer produces: small, and different per channel. */
        scale_tensor[oc] = ldexp(1.0, -12) * (1.0 + (double)(oc % 7u) * 0.13);
    }

    cnn_accel_model_reset(&model);
    cnn_accel_model_bind(&transport, &model);

    status = cnn_accel_open(&device, &transport, frame_buffer,
                            sizeof(frame_buffer));
    check_eq(status, CNN_ACCEL_OK, "cnn_accel_open");

    status = cnn_accel_check_geometry(&device);
    check_eq(status, CNN_ACCEL_OK, "geometry matches the driver's build");

    memset(output_accel, 0x5A, sizeof(output_accel));
    status = cnn_conv2d_run(&device, &layer, input_tensor, weight_tensor,
                            bias_tensor, scale_tensor, output_accel,
                            &workspace);
    check_eq(status, CNN_ACCEL_OK, "cnn_conv2d_run");

    status = cnn_conv2d_reference(&layer, input_tensor, weight_tensor,
                                  bias_tensor, scale_tensor,
                                  output_reference);
    check_eq(status, CNN_ACCEL_OK, "cnn_conv2d_reference");

    for (size_t i = 0; i < (size_t)positions * layer.out_c; i++) {
        if (output_accel[i] != output_reference[i]) {
            if (mismatches < 4) {
                printf("  FAIL: element %zu (position %zu, channel %zu): "
                       "reference %d, accelerator %d\n",
                       i, i / layer.out_c, i % layer.out_c,
                       output_reference[i], output_accel[i]);
            }
            mismatches++;
        }
    }
    checks++;
    if (mismatches != 0) {
        failures++;
        printf("  FAIL: %d of %zu outputs differ\n", mismatches,
               (size_t)positions * layer.out_c);
    }

    check_eq(model.error, 0, "the accelerator raised no protocol error");
    check_eq((long)model.vectors,
             (long)((size_t)positions *
                    ((depth + CNN_ACCEL_ARRAY_N - 1u) / CNN_ACCEL_ARRAY_N) *
                    ((layer.out_c + CNN_ACCEL_ARRAY_N - 1u) /
                     CNN_ACCEL_ARRAY_N)),
             "vectors processed matches the tiling");
}

static cnn_conv2d_layer base_layer(void)
{
    cnn_conv2d_layer layer;
    memset(&layer, 0, sizeof(layer));
    layer.stride_h = 1u;
    layer.stride_w = 1u;
    layer.input_zero_point = 0;
    layer.output_zero_point = 0;
    layer.fused_relu = 0;
    return layer;
}

static void test_convolutions(void)
{
    cnn_conv2d_layer layer;

    /* The reduction is exactly one tile: no accumulation across tiles. */
    layer = base_layer();
    layer.in_h = 6u; layer.in_w = 6u; layer.in_c = 16u;
    layer.out_c = 16u; layer.kernel_h = 1u; layer.kernel_w = 1u;
    run_layer_case("1x1, one reduction tile", layer);

    /* A reduction of 288 - eighteen tiles - which is where the accelerator's
     * accumulator buffer is doing the work. */
    layer = base_layer();
    layer.in_h = 8u; layer.in_w = 8u; layer.in_c = 32u;
    layer.out_c = 16u; layer.kernel_h = 3u; layer.kernel_w = 3u;
    layer.pad_h = 1u; layer.pad_w = 1u;
    run_layer_case("3x3 padded, eighteen reduction tiles", layer);

    /* Padding with a non-zero input zero point, which is what a real
     * asymmetrically quantised activation has. */
    layer = base_layer();
    layer.in_h = 7u; layer.in_w = 7u; layer.in_c = 24u;
    layer.out_c = 32u; layer.kernel_h = 3u; layer.kernel_w = 3u;
    layer.pad_h = 1u; layer.pad_w = 1u;
    layer.input_zero_point = -12;
    layer.output_zero_point = 5;
    run_layer_case("3x3 with a non-zero input zero point", layer);

    /* Dimensions that are not multiples of the array, so both the reduction
     * and the channel tiles have a tail that must be zero padded. */
    layer = base_layer();
    layer.in_h = 5u; layer.in_w = 5u; layer.in_c = 21u;
    layer.out_c = 19u; layer.kernel_h = 3u; layer.kernel_w = 3u;
    layer.pad_h = 1u; layer.pad_w = 1u;
    layer.input_zero_point = 7;
    run_layer_case("ragged channel and reduction tails", layer);

    /* A stride, so the im2col index arithmetic is exercised properly. */
    layer = base_layer();
    layer.in_h = 9u; layer.in_w = 9u; layer.in_c = 16u;
    layer.out_c = 16u; layer.kernel_h = 3u; layer.kernel_w = 3u;
    layer.stride_h = 2u; layer.stride_w = 2u;
    run_layer_case("3x3 stride 2, no padding", layer);

    /* A fused ReLU, which must floor at the output zero point. */
    layer = base_layer();
    layer.in_h = 6u; layer.in_w = 6u; layer.in_c = 32u;
    layer.out_c = 24u; layer.kernel_h = 3u; layer.kernel_w = 3u;
    layer.pad_h = 1u; layer.pad_w = 1u;
    layer.output_zero_point = -8;
    layer.fused_relu = 1;
    run_layer_case("3x3 with a fused ReLU", layer);
}

/*===========================================================================
 * Frame layout
 *=========================================================================*/
static void test_frame_layout(void)
{
    cnn_accel_model model;
    cnn_accel_transport transport;
    cnn_accel device;
    cnn_accel_channel channels[CNN_ACCEL_ARRAY_N];
    cnn_accel_output_format format = { -3, -3, 120 };
    int8_t tile[CNN_ACCEL_ARRAY_N * CNN_ACCEL_ARRAY_N];

    printf("test_frame_layout\n");

    cnn_accel_model_reset(&model);
    cnn_accel_model_bind(&transport, &model);
    check_eq(cnn_accel_open(&device, &transport, frame_buffer,
                            sizeof(frame_buffer)), CNN_ACCEL_OK, "open");

    for (unsigned k = 0; k < CNN_ACCEL_ARRAY_N; k++) {
        for (unsigned m = 0; m < CNN_ACCEL_ARRAY_N; m++) {
            tile[k * CNN_ACCEL_ARRAY_N + m] = (int8_t)(k * 16u + m);
        }
    }
    check_eq(cnn_accel_load_weights(&device, tile), CNN_ACCEL_OK,
             "load weights");
    check(memcmp(model.weights, tile, sizeof(tile)) == 0,
          "the weight tile arrives in [reduction][channel] order");

    for (unsigned m = 0; m < CNN_ACCEL_ARRAY_N; m++) {
        channels[m].bias  = (int32_t)m * -100000;
        channels[m].mult  = 0x00ABCDEFu + m;
        channels[m].shift = (uint8_t)(m % 40u);
    }
    check_eq(cnn_accel_load_params(&device, channels, &format), CNN_ACCEL_OK,
             "load params");

    for (unsigned m = 0; m < CNN_ACCEL_ARRAY_N; m++) {
        check_eq(model.channels[m].bias, channels[m].bias,
                 "bias survives the frame");
        check_eq((long)model.channels[m].mult, (long)channels[m].mult,
                 "multiplier survives the frame");
        check_eq(model.channels[m].shift, channels[m].shift,
                 "shift survives the frame");
    }
    check_eq(model.format.zero_point, format.zero_point,
             "output zero point survives the header");
    check_eq(model.format.min, format.min, "clamp floor survives the header");
    check_eq(model.format.max, format.max, "clamp ceiling survives the header");

    /* Parameters the frame format cannot express are refused rather than
     * truncated into something plausible. */
    channels[0].mult = CNN_ACCEL_MULT_MAX + 1u;
    check(cnn_accel_load_params(&device, channels, &format) != CNN_ACCEL_OK,
          "an over-wide multiplier is refused");
    channels[0].mult = 1u;
    channels[0].shift = (uint8_t)(CNN_ACCEL_SHIFT_MAX + 1u);
    check(cnn_accel_load_params(&device, channels, &format) != CNN_ACCEL_OK,
          "an over-wide shift is refused");
}

/*===========================================================================
 * main
 *=========================================================================*/
int main(void)
{
    printf("cnn_accel host self-test (ARRAY_N=%u, ACC_DEPTH=%u)\n\n",
           (unsigned)CNN_ACCEL_ARRAY_N, (unsigned)CNN_ACCEL_ACC_DEPTH);

    test_quant_scale();
    test_quant_requantise();
    test_zero_point_folding();
    test_frame_layout();
    test_convolutions();

    printf("\n%d check(s), %d failure(s)\n", checks, failures);
    if (failures != 0) {
        printf("TEST FAILED\n");
        return 1;
    }
    printf("TEST PASSED\n");
    return 0;
}
