/*=============================================================================
 * cnn_accel.c - frame construction and command sequencing
 *
 * Everything here is byte layout. The accelerator's frame format is defined by
 * the RTL in ip/ml/cnn_accel, and this file is the other half of that
 * contract; the two are checked against each other by the cocotb regression
 * on one side and the host self-test on the other.
 *
 * Byte order
 *   The A53 is little endian and the DMA moves memory bytes in order onto the
 *   stream, so memory byte n lands on tdata[8n+7 : 8n]. That is what makes a
 *   uint64_t header written at offset zero appear in the low bits of the beat,
 *   and what makes lane m of a vector simply be byte m. Nothing here needs to
 *   swap anything, but it is only true because of that chain of assumptions,
 *   so it is written down rather than left to be rediscovered.
 *
 * Copyright (c) 2026 SoC IP Portfolio Contributors
 * SPDX-License-Identifier: Apache-2.0
 *=============================================================================
 */
#include "cnn_accel.h"

#include <string.h>

/*---------------------------------------------------------------------------
 * Header construction
 *-------------------------------------------------------------------------*/
static void put_header(uint8_t *beat, uint8_t opcode, uint16_t count,
                       uint8_t flags, const cnn_accel_output_format *format)
{
    memset(beat, 0, CNN_ACCEL_BEAT_BYTES);

    beat[0] = opcode;
    beat[1] = (uint8_t)(flags & 0x03u);
    beat[2] = (uint8_t)(count & 0xFFu);
    beat[3] = (uint8_t)(count >> 8);

    if (format != NULL) {
        beat[4] = (uint8_t)format->zero_point;
        beat[5] = (uint8_t)format->min;
        beat[6] = (uint8_t)format->max;
    }
}

size_t cnn_accel_frame_bytes(uint16_t count)
{
    return ((size_t)count + 1u) * CNN_ACCEL_BEAT_BYTES;
}

/*---------------------------------------------------------------------------
 * Open
 *-------------------------------------------------------------------------*/
int cnn_accel_open(cnn_accel *dev, const cnn_accel_transport *transport,
                   void *frame_buffer, size_t frame_bytes)
{
    if (dev == NULL || transport == NULL || frame_buffer == NULL) {
        return CNN_ACCEL_ERR_ARG;
    }
    if (transport->send == NULL || transport->recv_start == NULL ||
        transport->recv_wait == NULL) {
        return CNN_ACCEL_ERR_ARG;
    }
    /* Every frame this driver can build is at least a header plus ARRAY_N
     * payload beats; refusing a buffer that small here is cheaper than
     * discovering it as a DMA writing past the end of one. */
    if (frame_bytes < cnn_accel_frame_bytes(CNN_ACCEL_ARRAY_N)) {
        return CNN_ACCEL_ERR_ARG;
    }
    if (((uintptr_t)frame_buffer % CNN_ACCEL_CACHE_LINE) != 0u) {
        return CNN_ACCEL_ERR_ARG;
    }

    dev->transport   = *transport;
    dev->frame       = (uint8_t *)frame_buffer;
    dev->frame_bytes = frame_bytes;
    dev->frames_sent = 0u;
    return CNN_ACCEL_OK;
}

/*---------------------------------------------------------------------------
 * Commands with no reply
 *-------------------------------------------------------------------------*/
static int send_frame(cnn_accel *dev, size_t beats)
{
    int status = dev->transport.send(dev->transport.ctx, dev->frame,
                                     beats * CNN_ACCEL_BEAT_BYTES);
    if (status != 0) {
        return CNN_ACCEL_ERR_TRANSPORT;
    }
    dev->frames_sent++;
    return CNN_ACCEL_OK;
}

int cnn_accel_nop(cnn_accel *dev)
{
    if (dev == NULL) {
        return CNN_ACCEL_ERR_ARG;
    }
    put_header(dev->frame, CNN_ACCEL_OP_NOP, 0u, 0u, NULL);
    return send_frame(dev, 1u);
}

int cnn_accel_load_weights(cnn_accel *dev, const int8_t *weights)
{
    if (dev == NULL || weights == NULL) {
        return CNN_ACCEL_ERR_ARG;
    }

    put_header(dev->frame, CNN_ACCEL_OP_LOAD_WEIGHTS, CNN_ACCEL_ARRAY_N, 0u,
               NULL);

    /* Row k of the tile becomes beat k, and lane m of that beat is the weight
     * for output channel m. Rows go out in natural order because the array's
     * load chain runs south to north. */
    memcpy(dev->frame + CNN_ACCEL_BEAT_BYTES, weights,
           (size_t)CNN_ACCEL_ARRAY_N * CNN_ACCEL_BEAT_BYTES);

    return send_frame(dev, 1u + CNN_ACCEL_ARRAY_N);
}

int cnn_accel_load_params(cnn_accel *dev, const cnn_accel_channel *channels,
                          const cnn_accel_output_format *format)
{
    if (dev == NULL || channels == NULL || format == NULL) {
        return CNN_ACCEL_ERR_ARG;
    }
    if (format->min > format->max) {
        return CNN_ACCEL_ERR_ARG;
    }

    put_header(dev->frame, CNN_ACCEL_OP_LOAD_PARAMS, CNN_ACCEL_ARRAY_N, 0u,
               format);

    for (unsigned m = 0; m < CNN_ACCEL_ARRAY_N; m++) {
        uint8_t *beat = dev->frame + (size_t)(m + 1u) * CNN_ACCEL_BEAT_BYTES;
        uint32_t bias = (uint32_t)channels[m].bias;

        if (channels[m].mult > CNN_ACCEL_MULT_MAX ||
            channels[m].shift > CNN_ACCEL_SHIFT_MAX) {
            return CNN_ACCEL_ERR_ARG;
        }

        memset(beat, 0, CNN_ACCEL_BEAT_BYTES);

        beat[0] = (uint8_t)(bias);
        beat[1] = (uint8_t)(bias >> 8);
        beat[2] = (uint8_t)(bias >> 16);
        beat[3] = (uint8_t)(bias >> 24);

        beat[4] = (uint8_t)(channels[m].mult);
        beat[5] = (uint8_t)(channels[m].mult >> 8);
        beat[6] = (uint8_t)(channels[m].mult >> 16);

        beat[7] = (uint8_t)(channels[m].shift & CNN_ACCEL_SHIFT_MAX);
    }

    return send_frame(dev, 1u + CNN_ACCEL_ARRAY_N);
}

/*---------------------------------------------------------------------------
 * Compute
 *-------------------------------------------------------------------------*/
int cnn_accel_compute(cnn_accel *dev, const int8_t *vectors, uint16_t count,
                      unsigned flags, int8_t *results)
{
    size_t received = 0u;
    size_t expected;
    int status;

    if (dev == NULL || vectors == NULL || count == 0u) {
        return CNN_ACCEL_ERR_ARG;
    }
    if (count > CNN_ACCEL_ACC_DEPTH) {
        return CNN_ACCEL_ERR_ARG;
    }
    if (cnn_accel_frame_bytes(count) > dev->frame_bytes) {
        return CNN_ACCEL_ERR_ARG;
    }
    if ((flags & CNN_ACCEL_LAST_TILE) != 0u && results == NULL) {
        return CNN_ACCEL_ERR_ARG;
    }

    put_header(dev->frame, CNN_ACCEL_OP_COMPUTE, count, (uint8_t)flags, NULL);
    memcpy(dev->frame + CNN_ACCEL_BEAT_BYTES, vectors,
           (size_t)count * CNN_ACCEL_BEAT_BYTES);

    /* The receive has to be armed before the compute frame goes out. A batch
     * can be far longer than the accelerator's output buffer, so if nothing
     * were draining it the accelerator would stop accepting activations and
     * the send would never finish. */
    expected = (size_t)count * CNN_ACCEL_BEAT_BYTES;
    if ((flags & CNN_ACCEL_LAST_TILE) != 0u) {
        status = dev->transport.recv_start(dev->transport.ctx, results,
                                           expected);
        if (status != 0) {
            return CNN_ACCEL_ERR_TRANSPORT;
        }
    }

    status = send_frame(dev, 1u + (size_t)count);
    if (status != CNN_ACCEL_OK) {
        return status;
    }

    if ((flags & CNN_ACCEL_LAST_TILE) == 0u) {
        return CNN_ACCEL_OK;
    }

    status = dev->transport.recv_wait(dev->transport.ctx, &received);
    if (status != 0) {
        return CNN_ACCEL_ERR_TRANSPORT;
    }
    if (received != expected) {
        return CNN_ACCEL_ERR_SHORT_READ;
    }

    return CNN_ACCEL_OK;
}

/*---------------------------------------------------------------------------
 * Status
 *-------------------------------------------------------------------------*/
int cnn_accel_status_read(cnn_accel *dev, cnn_accel_status *status_out)
{
    /* Two beats: identity and flags, then the counters. */
    uint8_t reply[2 * CNN_ACCEL_BEAT_BYTES] CNN_ACCEL_ALIGNED;
    size_t received = 0u;
    int status;

    if (dev == NULL || status_out == NULL) {
        return CNN_ACCEL_ERR_ARG;
    }

    put_header(dev->frame, CNN_ACCEL_OP_STATUS, 0u, 0u, NULL);

    status = dev->transport.recv_start(dev->transport.ctx, reply,
                                       sizeof(reply));
    if (status != 0) {
        return CNN_ACCEL_ERR_TRANSPORT;
    }

    status = send_frame(dev, 1u);
    if (status != CNN_ACCEL_OK) {
        return status;
    }

    status = dev->transport.recv_wait(dev->transport.ctx, &received);
    if (status != 0) {
        return CNN_ACCEL_ERR_TRANSPORT;
    }
    if (received != sizeof(reply)) {
        return CNN_ACCEL_ERR_SHORT_READ;
    }

    status_out->version    = reply[0];
    status_out->array_n    = reply[1];
    status_out->data_width = reply[2];
    status_out->acc_width  = reply[3];
    status_out->error      = (reply[4] & 0x01u) != 0u;
    status_out->saturated  = (reply[4] & 0x02u) != 0u;
    status_out->busy       = (reply[4] & 0x04u) != 0u;
    status_out->acc_depth  = (uint16_t)((uint16_t)reply[5] |
                                        ((uint16_t)reply[6] << 8));
    status_out->out_fifo_depth = reply[7];

    status_out->jobs = (uint32_t)reply[CNN_ACCEL_BEAT_BYTES + 0]
                     | ((uint32_t)reply[CNN_ACCEL_BEAT_BYTES + 1] << 8)
                     | ((uint32_t)reply[CNN_ACCEL_BEAT_BYTES + 2] << 16)
                     | ((uint32_t)reply[CNN_ACCEL_BEAT_BYTES + 3] << 24);

    status_out->vectors = (uint32_t)reply[CNN_ACCEL_BEAT_BYTES + 4]
                        | ((uint32_t)reply[CNN_ACCEL_BEAT_BYTES + 5] << 8)
                        | ((uint32_t)reply[CNN_ACCEL_BEAT_BYTES + 6] << 16)
                        | ((uint32_t)reply[CNN_ACCEL_BEAT_BYTES + 7] << 24);

    return CNN_ACCEL_OK;
}

int cnn_accel_check_geometry(cnn_accel *dev)
{
    cnn_accel_status status;
    int result = cnn_accel_status_read(dev, &status);

    if (result != CNN_ACCEL_OK) {
        return result;
    }
    if (status.array_n != CNN_ACCEL_ARRAY_N || status.data_width != 8u) {
        return CNN_ACCEL_ERR_GEOMETRY;
    }
    /* A driver that batches more vectors than the accumulator holds would have
     * every frame past the first rejected, so the mismatch is worth catching
     * here rather than one job at a time. */
    if (status.acc_depth < CNN_ACCEL_ACC_DEPTH) {
        return CNN_ACCEL_ERR_GEOMETRY;
    }
    if (status.error) {
        return CNN_ACCEL_ERR_DEVICE;
    }
    return CNN_ACCEL_OK;
}
