/*=============================================================================
 * main.c - bare-metal Cortex-A53 demonstration of the cnn_accel accelerator
 *
 * Runs one quantised convolution layer on the accelerator, runs the same layer
 * on the A53 with identical arithmetic, and compares them element by element.
 * A quantised accelerator that is nearly right is worse than one that is
 * obviously broken, so the check is an equality over every output rather than
 * a tolerance.
 *
 * Then it times both, which is the number the design exists for.
 *
 * Build with the Vitis standalone BSP; see the Makefile.
 *
 * Copyright (c) 2026 SoC IP Portfolio Contributors
 * SPDX-License-Identifier: Apache-2.0
 *=============================================================================
 */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "cnn_accel.h"
#include "cnn_accel_conv2d.h"
#include "cnn_accel_dma.h"
#include "cnn_accel_quant.h"

#include "xil_cache.h"
#include "xil_printf.h"
#include "xparameters.h"
#include "xtime_l.h"

/*---------------------------------------------------------------------------
 * The layer. A 3x3 convolution over 32 input channels into 16 output
 * channels on a 16x16 feature map - the shape of an early layer of a small
 * classifier, and big enough that the accelerator's advantage is real rather
 * than lost in the frame overhead.
 *
 *   reduction depth  3 * 3 * 32 = 288, so eighteen weight tiles
 *   positions        16 * 16    = 256, exactly one accumulator buffer
 *   multiply-accumulates  256 * 288 * 16 = 1179648
 *-------------------------------------------------------------------------*/
#define IN_H   16u
#define IN_W   16u
#define IN_C   32u
#define OUT_C  16u
#define K      3u
#define PAD    1u
#define STRIDE 1u

#define OUT_H ((IN_H + 2u * PAD - K) / STRIDE + 1u)
#define OUT_W ((IN_W + 2u * PAD - K) / STRIDE + 1u)

#define REDUCTION (K * K * IN_C)
#define POSITIONS (OUT_H * OUT_W)

#ifndef CNN_ACCEL_DMA_DEVICE_ID
#define CNN_ACCEL_DMA_DEVICE_ID XPAR_AXIDMA_0_DEVICE_ID
#endif

/* Statically allocated and cache-line aligned. Anything the DMA touches has to
 * be, and a bare-metal driver that allocates is one that can fail halfway
 * through a layer. */
static int8_t  input_tensor[IN_H * IN_W * IN_C]     CNN_ACCEL_ALIGNED;
static int8_t  weight_tensor[OUT_C * REDUCTION]     CNN_ACCEL_ALIGNED;
static int32_t bias_tensor[OUT_C];
static double  scale_tensor[OUT_C];
static int8_t  output_accel[POSITIONS * OUT_C]      CNN_ACCEL_ALIGNED;
static int8_t  output_reference[POSITIONS * OUT_C]  CNN_ACCEL_ALIGNED;

static cnn_conv2d_workspace workspace CNN_ACCEL_ALIGNED;
static uint8_t frame_buffer[(CNN_ACCEL_ACC_DEPTH + 1) * CNN_ACCEL_BEAT_BYTES]
    CNN_ACCEL_ALIGNED;

static cnn_accel_dma dma;
static cnn_accel     device;

/*---------------------------------------------------------------------------
 * Reproducible stimulus, so a failure on the board can be replayed on a host.
 *-------------------------------------------------------------------------*/
static uint32_t rng_state = 0x1234567u;

static uint32_t next_random(void)
{
    rng_state = rng_state * 1664525u + 1013904223u;
    return rng_state;
}

static void build_layer(cnn_conv2d_layer *layer)
{
    memset(layer, 0, sizeof(*layer));
    layer->in_h = IN_H;   layer->in_w = IN_W;   layer->in_c = IN_C;
    layer->out_h = OUT_H; layer->out_w = OUT_W; layer->out_c = OUT_C;
    layer->kernel_h = K;  layer->kernel_w = K;
    layer->stride_h = STRIDE; layer->stride_w = STRIDE;
    layer->pad_h = PAD;   layer->pad_w = PAD;

    /* An asymmetrically quantised input, which is the normal case after a
     * ReLU: the data is one-sided, so the zero point is not zero. */
    layer->input_zero_point  = -12;
    layer->output_zero_point = -8;
    layer->fused_relu        = 1;

    for (size_t i = 0; i < sizeof(input_tensor); i++) {
        input_tensor[i] = (int8_t)(next_random() >> 24);
    }
    for (size_t i = 0; i < sizeof(weight_tensor); i++) {
        weight_tensor[i] = (int8_t)(next_random() >> 24);
    }
    for (unsigned oc = 0; oc < OUT_C; oc++) {
        bias_tensor[oc]  = (int32_t)(next_random() % 4001u) - 2000;
        /* Per-channel scales, as a real quantised model has. */
        scale_tensor[oc] = ldexp(1.0, -12) * (1.0 + (double)(oc % 7u) * 0.13);
    }
}

static uint64_t elapsed_us(XTime start, XTime end)
{
    /* The A53's generic timer runs at COUNTS_PER_SECOND. */
    return ((uint64_t)(end - start) * 1000000u) / COUNTS_PER_SECOND;
}

int main(void)
{
    cnn_conv2d_layer layer;
    cnn_accel_transport transport;
    cnn_accel_status status_reply;
    XTime start;
    XTime end;
    uint64_t accel_us;
    uint64_t reference_us;
    int status;
    unsigned mismatches = 0u;

    Xil_DCacheEnable();
    Xil_ICacheEnable();

    xil_printf("\r\n");
    xil_printf("cnn_accel demonstration\r\n");
    xil_printf("=======================\r\n");
    xil_printf("layer   : %ux%ux%u -> %ux%ux%u, %ux%u kernel, pad %u\r\n",
               IN_H, IN_W, IN_C, OUT_H, OUT_W, OUT_C, K, K, PAD);
    xil_printf("reduction %u over %u positions, %u MACs\r\n\r\n",
               REDUCTION, POSITIONS, POSITIONS * REDUCTION * OUT_C);

    status = cnn_accel_dma_open(&dma, CNN_ACCEL_DMA_DEVICE_ID);
    if (status != CNN_ACCEL_OK) {
        xil_printf("DMA initialisation failed (%d)\r\n", status);
        return 1;
    }
    cnn_accel_dma_bind(&transport, &dma);

    status = cnn_accel_open(&device, &transport, frame_buffer,
                            sizeof(frame_buffer));
    if (status != CNN_ACCEL_OK) {
        xil_printf("cnn_accel_open failed (%d)\r\n", status);
        return 1;
    }

    /* Ask the accelerator what it is before trusting it with a layer. A
     * driver built for the wrong array size produces garbage rather than an
     * error, and this is the only place that mismatch is cheap to find. */
    status = cnn_accel_status_read(&device, &status_reply);
    if (status != CNN_ACCEL_OK) {
        xil_printf("status read failed (%d) - is the stream connected?\r\n",
                   status);
        return 1;
    }
    xil_printf("device  : version %u, %ux%u array, int%u, acc %u bits\r\n",
               status_reply.version, status_reply.array_n, status_reply.array_n,
               status_reply.data_width, status_reply.acc_width);

    if (status_reply.array_n != CNN_ACCEL_ARRAY_N) {
        xil_printf("geometry mismatch: bitstream has %u, driver built for %u\r\n",
                   status_reply.array_n, (unsigned)CNN_ACCEL_ARRAY_N);
        return 1;
    }

    build_layer(&layer);

    /*-----------------------------------------------------------------------
     * The accelerator
     *---------------------------------------------------------------------*/
    memset(output_accel, 0, sizeof(output_accel));
    XTime_GetTime(&start);
    status = cnn_conv2d_run(&device, &layer, input_tensor, weight_tensor,
                            bias_tensor, scale_tensor, output_accel,
                            &workspace);
    XTime_GetTime(&end);
    accel_us = elapsed_us(start, end);

    if (status != CNN_ACCEL_OK) {
        xil_printf("cnn_conv2d_run failed (%d)\r\n", status);
        return 1;
    }

    /*-----------------------------------------------------------------------
     * The same layer on the processor
     *---------------------------------------------------------------------*/
    XTime_GetTime(&start);
    status = cnn_conv2d_reference(&layer, input_tensor, weight_tensor,
                                  bias_tensor, scale_tensor,
                                  output_reference);
    XTime_GetTime(&end);
    reference_us = elapsed_us(start, end);

    if (status != CNN_ACCEL_OK) {
        xil_printf("cnn_conv2d_reference failed (%d)\r\n", status);
        return 1;
    }

    /*-----------------------------------------------------------------------
     * Compare, then report
     *---------------------------------------------------------------------*/
    for (size_t i = 0; i < (size_t)POSITIONS * OUT_C; i++) {
        if (output_accel[i] != output_reference[i]) {
            if (mismatches < 8u) {
                xil_printf("  mismatch at %u: reference %d, accelerator %d\r\n",
                           (unsigned)i, output_reference[i], output_accel[i]);
            }
            mismatches++;
        }
    }

    status = cnn_accel_status_read(&device, &status_reply);
    if (status == CNN_ACCEL_OK) {
        xil_printf("\r\ncounters: %u job(s), %u vector(s)%s\r\n",
                   (unsigned)status_reply.jobs, (unsigned)status_reply.vectors,
                   status_reply.saturated ? ", some results saturated" : "");
        if (status_reply.error) {
            xil_printf("the accelerator raised its protocol error flag\r\n");
        }
    }

    xil_printf("\r\naccelerator : %u us\r\n", (unsigned)accel_us);
    xil_printf("processor   : %u us\r\n", (unsigned)reference_us);
    if (accel_us != 0u) {
        xil_printf("speed-up    : %u.%02ux\r\n",
                   (unsigned)(reference_us / accel_us),
                   (unsigned)((reference_us * 100u / accel_us) % 100u));
    }

    if (mismatches != 0u) {
        xil_printf("\r\nTEST FAILED: %u of %u outputs differ\r\n",
                   mismatches, POSITIONS * OUT_C);
        return 1;
    }

    xil_printf("\r\nTEST PASSED: %u outputs match the reference exactly\r\n",
               POSITIONS * OUT_C);

    Xil_DCacheDisable();
    return 0;
}
