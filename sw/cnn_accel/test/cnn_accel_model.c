/*=============================================================================
 * cnn_accel_model.c - a software model of the accelerator, as a transport
 *
 * Implements the same frame protocol and the same arithmetic as the RTL, so
 * the driver can be exercised end to end on a development machine: the tiling
 * in cnn_accel_conv2d.c, the quantisation preparation, and the byte layout of
 * every frame.
 *
 * What this does and does not prove
 *   It proves the driver is internally consistent and that its lowering and
 *   quantisation are right, which is the part the RTL regression cannot reach
 *   - the hardware has never heard of a convolution.
 *
 *   It does not independently confirm the frame layout, because this model and
 *   the driver were written from the same reading of the RTL. The authority on
 *   the layout is ip/ml/cnn_accel/cocotb/test_cnn_accel.py, which drives the
 *   real design.
 *
 * One transfer is one frame here, which is how the DMA behaves in simple mode:
 * TLAST is asserted at the end of a transfer, so a frame boundary and a
 * transfer boundary are the same thing.
 *
 * Copyright (c) 2026 SoC IP Portfolio Contributors
 * SPDX-License-Identifier: Apache-2.0
 *=============================================================================
 */
#include "cnn_accel_model.h"

#include <string.h>

static int32_t load_le32(const uint8_t *p)
{
    return (int32_t)((uint32_t)p[0] | ((uint32_t)p[1] << 8) |
                     ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24));
}

static void store_le32(uint8_t *p, uint32_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
    p[2] = (uint8_t)(value >> 16);
    p[3] = (uint8_t)(value >> 24);
}

void cnn_accel_model_reset(cnn_accel_model *model)
{
    memset(model, 0, sizeof(*model));
    model->format.zero_point = 0;
    model->format.min = -128;
    model->format.max = 127;
}

/*---------------------------------------------------------------------------
 * Emit into the posted receive buffer, refusing to overrun it - which is what
 * the accelerator's TLAST plus the DMA's length would enforce on hardware.
 *-------------------------------------------------------------------------*/
static int emit(cnn_accel_model *model, const uint8_t *beat)
{
    if (model->rx_buffer == NULL ||
        model->rx_filled + CNN_ACCEL_BEAT_BYTES > model->rx_bytes) {
        model->overrun = 1;
        return -1;
    }
    memcpy(model->rx_buffer + model->rx_filled, beat, CNN_ACCEL_BEAT_BYTES);
    model->rx_filled += CNN_ACCEL_BEAT_BYTES;
    return 0;
}

static int handle_compute(cnn_accel_model *model, const uint8_t *frame,
                          size_t beats, unsigned flags, uint16_t count)
{
    const size_t payload = beats - 1u;
    const int first = (flags & CNN_ACCEL_FIRST_TILE) != 0u;
    const int last  = (flags & CNN_ACCEL_LAST_TILE) != 0u;
    size_t vectors = payload;

    if (payload != count) {
        model->error = 1;                 /* TLAST wins, count is the check */
        if (payload > count) {
            vectors = count;              /* surplus beats are dropped */
        }
    }
    if (vectors > CNN_ACCEL_ACC_DEPTH) {
        model->error = 1;
        return -1;
    }

    if (first) {
        model->chunk_length = vectors;
    } else if (model->chunk_length != vectors) {
        model->error = 1;
    }

    for (size_t v = 0; v < vectors; v++) {
        const uint8_t *beat = frame + (v + 1u) * CNN_ACCEL_BEAT_BYTES;

        for (unsigned m = 0; m < CNN_ACCEL_ARRAY_N; m++) {
            int32_t total = 0;
            for (unsigned k = 0; k < CNN_ACCEL_ARRAY_N; k++) {
                total += (int32_t)model->weights[k][m] *
                         (int32_t)(int8_t)beat[k];
            }
            model->accumulator[v][m] = first ? total
                                             : model->accumulator[v][m] + total;
        }
        model->vectors++;
    }

    if (!last) {
        return 0;
    }

    for (size_t v = 0; v < vectors; v++) {
        uint8_t out[CNN_ACCEL_BEAT_BYTES];
        for (unsigned m = 0; m < CNN_ACCEL_ARRAY_N; m++) {
            out[m] = (uint8_t)cnn_quant_requantise(model->accumulator[v][m],
                                                   &model->channels[m],
                                                   &model->format);
        }
        if (emit(model, out) != 0) {
            return -1;
        }
    }
    model->jobs++;
    return 0;
}

static int handle_status(cnn_accel_model *model)
{
    uint8_t beat[CNN_ACCEL_BEAT_BYTES];

    memset(beat, 0, sizeof(beat));
    beat[0] = 1u;                          /* version */
    beat[1] = (uint8_t)CNN_ACCEL_ARRAY_N;
    beat[2] = 8u;                          /* data width */
    beat[3] = 32u;                         /* accumulator width */
    beat[4] = (uint8_t)(model->error ? 1u : 0u);
    beat[5] = (uint8_t)(CNN_ACCEL_ACC_DEPTH & 0xFFu);
    beat[6] = (uint8_t)((CNN_ACCEL_ACC_DEPTH >> 8) & 0xFFu);
    beat[7] = 64u;                         /* output buffer depth */
    if (emit(model, beat) != 0) {
        return -1;
    }

    memset(beat, 0, sizeof(beat));
    store_le32(&beat[0], model->jobs);
    store_le32(&beat[4], model->vectors);
    return emit(model, beat);
}

int cnn_accel_model_send(void *ctx, const void *frame_bytes, size_t bytes)
{
    cnn_accel_model *model = (cnn_accel_model *)ctx;
    const uint8_t *frame = (const uint8_t *)frame_bytes;
    size_t beats;
    uint8_t opcode;
    uint8_t flags;
    uint16_t count;

    if (bytes == 0u || (bytes % CNN_ACCEL_BEAT_BYTES) != 0u) {
        return -1;
    }

    beats  = bytes / CNN_ACCEL_BEAT_BYTES;
    opcode = frame[0];
    flags  = (uint8_t)(frame[1] & 0x03u);
    count  = (uint16_t)((uint16_t)frame[2] | ((uint16_t)frame[3] << 8));

    model->frames++;

    switch (opcode) {
    case CNN_ACCEL_OP_NOP:
        if (beats != 1u || count != 0u) {
            model->error = 1;
        } else {
            model->error = 0;
        }
        return 0;

    case CNN_ACCEL_OP_LOAD_WEIGHTS:
        if (beats != 1u + CNN_ACCEL_ARRAY_N || count != CNN_ACCEL_ARRAY_N) {
            /* A tile of the wrong length is misaligned rather than merely
             * incomplete, so the hardware refuses to publish it. */
            model->error = 1;
            return 0;
        }
        for (unsigned k = 0; k < CNN_ACCEL_ARRAY_N; k++) {
            const uint8_t *beat = frame + (k + 1u) * CNN_ACCEL_BEAT_BYTES;
            for (unsigned m = 0; m < CNN_ACCEL_ARRAY_N; m++) {
                model->weights[k][m] = (int8_t)beat[m];
            }
        }
        return 0;

    case CNN_ACCEL_OP_LOAD_PARAMS:
        if (beats != 1u + CNN_ACCEL_ARRAY_N || count != CNN_ACCEL_ARRAY_N) {
            model->error = 1;
            return 0;
        }
        model->format.zero_point = (int8_t)frame[4];
        model->format.min        = (int8_t)frame[5];
        model->format.max        = (int8_t)frame[6];
        for (unsigned m = 0; m < CNN_ACCEL_ARRAY_N; m++) {
            const uint8_t *beat = frame + (m + 1u) * CNN_ACCEL_BEAT_BYTES;
            model->channels[m].bias  = load_le32(&beat[0]);
            model->channels[m].mult  = (uint32_t)beat[4]
                                     | ((uint32_t)beat[5] << 8)
                                     | ((uint32_t)beat[6] << 16);
            model->channels[m].shift = (uint8_t)(beat[7] & CNN_ACCEL_SHIFT_MAX);
        }
        return 0;

    case CNN_ACCEL_OP_COMPUTE:
        return handle_compute(model, frame, beats, flags, count);

    case CNN_ACCEL_OP_STATUS:
        if (beats != 1u || count != 0u) {
            model->error = 1;
            return 0;
        }
        return handle_status(model);

    default:
        model->error = 1;
        return 0;
    }
}

int cnn_accel_model_recv_start(void *ctx, void *buffer, size_t bytes)
{
    cnn_accel_model *model = (cnn_accel_model *)ctx;

    model->rx_buffer = (uint8_t *)buffer;
    model->rx_bytes  = bytes;
    model->rx_filled = 0u;
    return 0;
}

int cnn_accel_model_recv_wait(void *ctx, size_t *received)
{
    cnn_accel_model *model = (cnn_accel_model *)ctx;

    if (model->overrun) {
        return -1;
    }
    *received = model->rx_filled;
    model->rx_buffer = NULL;
    model->rx_bytes  = 0u;
    return 0;
}

void cnn_accel_model_bind(cnn_accel_transport *transport,
                          cnn_accel_model *model)
{
    transport->send       = cnn_accel_model_send;
    transport->recv_start = cnn_accel_model_recv_start;
    transport->recv_wait  = cnn_accel_model_recv_wait;
    transport->ctx        = model;
}
