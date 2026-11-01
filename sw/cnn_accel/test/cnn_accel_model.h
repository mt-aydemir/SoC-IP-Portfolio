/*=============================================================================
 * cnn_accel_model.h - software model of the accelerator, usable as a transport
 *
 * Copyright (c) 2026 SoC IP Portfolio Contributors
 * SPDX-License-Identifier: Apache-2.0
 *=============================================================================
 */
#ifndef CNN_ACCEL_MODEL_H
#define CNN_ACCEL_MODEL_H

#include <stddef.h>
#include <stdint.h>

#include "cnn_accel.h"
#include "cnn_accel_quant.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cnn_accel_model {
    int8_t                  weights[CNN_ACCEL_ARRAY_N][CNN_ACCEL_ARRAY_N];
    cnn_accel_channel       channels[CNN_ACCEL_ARRAY_N];
    cnn_accel_output_format format;

    int32_t  accumulator[CNN_ACCEL_ACC_DEPTH][CNN_ACCEL_ARRAY_N];
    size_t   chunk_length;

    uint8_t *rx_buffer;
    size_t   rx_bytes;
    size_t   rx_filled;
    int      overrun;

    int      error;
    uint32_t frames;
    uint32_t jobs;
    uint32_t vectors;
} cnn_accel_model;

void cnn_accel_model_reset(cnn_accel_model *model);
void cnn_accel_model_bind(cnn_accel_transport *transport,
                          cnn_accel_model *model);

int cnn_accel_model_send(void *ctx, const void *frame_bytes, size_t bytes);
int cnn_accel_model_recv_start(void *ctx, void *buffer, size_t bytes);
int cnn_accel_model_recv_wait(void *ctx, size_t *received);

#ifdef __cplusplus
}
#endif

#endif /* CNN_ACCEL_MODEL_H */
