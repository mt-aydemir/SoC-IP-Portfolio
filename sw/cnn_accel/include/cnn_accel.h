/*=============================================================================
 * cnn_accel.h - host interface to the cnn_accel inference accelerator
 *
 * The accelerator has no register interface. Every command is a TLAST
 * delimited frame on its AXI4-Stream sink, so this header is mostly a
 * description of that frame format plus the code that builds one.
 *
 * The transport is abstracted behind two pairs of function pointers rather
 * than calling the DMA directly. There are two reasons, and the second is the
 * important one:
 *
 *   * the same driver runs against an AXI DMA on hardware and against a
 *     software model of the RTL on a development machine, and
 *   * the model transport is what lets the driver's arithmetic be checked
 *     against the hardware's arithmetic on a host, in a normal unit test,
 *     rather than only on a board.
 *
 * Copyright (c) 2026 SoC IP Portfolio Contributors
 * SPDX-License-Identifier: Apache-2.0
 *=============================================================================
 */
#ifndef CNN_ACCEL_H
#define CNN_ACCEL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*---------------------------------------------------------------------------
 * Geometry.
 *
 * These must match the bitstream. They are compile-time because the frame
 * layout depends on them; cnn_accel_check_geometry() reads the accelerator's
 * STATUS reply and refuses to run if the two disagree, which turns a
 * bitstream/software mismatch into a start-up error instead of into results
 * that are wrong in a way no test would attribute to the right cause.
 *-------------------------------------------------------------------------*/
#ifndef CNN_ACCEL_ARRAY_N
#define CNN_ACCEL_ARRAY_N 16
#endif

#ifndef CNN_ACCEL_ACC_DEPTH
#define CNN_ACCEL_ACC_DEPTH 256
#endif

/* One AXI4-Stream beat is one int8 lane per array column. */
#define CNN_ACCEL_BEAT_BYTES (CNN_ACCEL_ARRAY_N)

#define CNN_ACCEL_MULT_BITS  24
#define CNN_ACCEL_SHIFT_BITS 6
#define CNN_ACCEL_MULT_MAX   ((uint32_t)((1u << CNN_ACCEL_MULT_BITS) - 1u))
#define CNN_ACCEL_SHIFT_MAX  ((uint8_t)((1u << CNN_ACCEL_SHIFT_BITS) - 1u))

/* The A53's cache line. Stream buffers are aligned to it and their lengths
 * rounded up to it, because an invalidate of a partial line either loses a
 * neighbouring variable's value or keeps a stale copy of the result. */
#define CNN_ACCEL_CACHE_LINE 64
#define CNN_ACCEL_ALIGNED __attribute__((aligned(CNN_ACCEL_CACHE_LINE)))

/*---------------------------------------------------------------------------
 * Frame format
 *-------------------------------------------------------------------------*/
enum cnn_accel_opcode {
    CNN_ACCEL_OP_NOP          = 0x00,
    CNN_ACCEL_OP_LOAD_WEIGHTS = 0x01,
    CNN_ACCEL_OP_LOAD_PARAMS  = 0x02,
    CNN_ACCEL_OP_COMPUTE      = 0x03,
    CNN_ACCEL_OP_STATUS       = 0x04
};

enum cnn_accel_compute_flags {
    /* Overwrite the accumulator rather than adding to it. */
    CNN_ACCEL_FIRST_TILE = 1u << 0,
    /* Requantise and emit a result frame. */
    CNN_ACCEL_LAST_TILE  = 1u << 1,
    /* A layer whose reduction fits in one tile. */
    CNN_ACCEL_ONLY_TILE  = (1u << 0) | (1u << 1)
};

/*---------------------------------------------------------------------------
 * Errors
 *-------------------------------------------------------------------------*/
enum cnn_accel_result {
    CNN_ACCEL_OK              =  0,
    CNN_ACCEL_ERR_ARG         = -1,  /* a caller argument is out of range */
    CNN_ACCEL_ERR_TRANSPORT   = -2,  /* the DMA reported a failure */
    CNN_ACCEL_ERR_TIMEOUT     = -3,
    CNN_ACCEL_ERR_SHORT_READ  = -4,  /* fewer result bytes than expected */
    CNN_ACCEL_ERR_GEOMETRY    = -5,  /* the bitstream is not what we expect */
    CNN_ACCEL_ERR_DEVICE      = -6   /* the accelerator raised its error flag */
};

/*---------------------------------------------------------------------------
 * Transport.
 *
 * `recv_start` posts a receive and returns immediately; `recv_wait` blocks for
 * it. They are separate because a batch can be longer than the accelerator's
 * output buffer, so the receive has to be armed before the compute frame is
 * sent or the accelerator would stall with nowhere to put its first results
 * and the send would never complete.
 *-------------------------------------------------------------------------*/
typedef struct cnn_accel_transport {
    int (*send)(void *ctx, const void *frame, size_t bytes);
    int (*recv_start)(void *ctx, void *buffer, size_t bytes);
    int (*recv_wait)(void *ctx, size_t *received);
    void *ctx;
} cnn_accel_transport;

/*---------------------------------------------------------------------------
 * Per-channel requantisation parameters.
 *
 * `bias` is the layer bias with the input zero-point correction already folded
 * in - see cnn_accel_quant.h. `mult` and `shift` are the fixed-point form of
 * the layer's rescaling factor.
 *-------------------------------------------------------------------------*/
typedef struct cnn_accel_channel {
    int32_t  bias;
    uint32_t mult;   /* unsigned, at most CNN_ACCEL_MULT_BITS wide */
    uint8_t  shift;  /* at most CNN_ACCEL_SHIFT_BITS wide */
} cnn_accel_channel;

typedef struct cnn_accel_output_format {
    int8_t zero_point;
    int8_t min;      /* raise to zero_point for a fused ReLU */
    int8_t max;
} cnn_accel_output_format;

/*---------------------------------------------------------------------------
 * Device handle.
 *
 * `frame` is the staging buffer every outgoing frame is built in. It must be
 * cache-line aligned and at least (1 + max(ARRAY_N, ACC_DEPTH)) beats long;
 * cnn_accel_frame_bytes() computes the size for a given batch.
 *-------------------------------------------------------------------------*/
typedef struct cnn_accel {
    cnn_accel_transport transport;
    uint8_t            *frame;
    size_t              frame_bytes;
    uint32_t            frames_sent;
} cnn_accel;

typedef struct cnn_accel_status {
    uint8_t  version;
    uint8_t  array_n;
    uint8_t  data_width;
    uint8_t  acc_width;
    uint16_t acc_depth;       /* longest batch the accelerator will accept */
    uint8_t  out_fifo_depth;  /* saturated to 255 by the reply format */
    int      error;
    int      saturated;
    int      busy;
    uint32_t jobs;
    uint32_t vectors;
} cnn_accel_status;

/*---------------------------------------------------------------------------
 * API
 *-------------------------------------------------------------------------*/

/* Bytes of staging buffer needed for a compute frame of `count` vectors. */
size_t cnn_accel_frame_bytes(uint16_t count);

/* Bind a transport and a staging buffer. Does not touch the hardware. */
int cnn_accel_open(cnn_accel *dev, const cnn_accel_transport *transport,
                   void *frame_buffer, size_t frame_bytes);

/* Read the accelerator's identity and counters. */
int cnn_accel_status_read(cnn_accel *dev, cnn_accel_status *status);

/* Read the identity and fail if it is not the geometry this build assumes. */
int cnn_accel_check_geometry(cnn_accel *dev);

/* Clear the sticky error, and fence: everything before it has been consumed. */
int cnn_accel_nop(cnn_accel *dev);

/* Publish a weight tile. `weights` is [ARRAY_N][ARRAY_N], row major, indexed
 * [reduction][output channel] - the same order the array holds it in, so a
 * caller that has already laid its weights out that way passes a pointer. */
int cnn_accel_load_weights(cnn_accel *dev, const int8_t *weights);

/* Load the per-channel requantisation parameters and the output format. */
int cnn_accel_load_params(cnn_accel *dev, const cnn_accel_channel *channels,
                          const cnn_accel_output_format *format);

/* Run one tile.
 *
 * `vectors` is [count][ARRAY_N] int8, row major. `results` receives
 * [count][ARRAY_N] int8 and may be NULL when CNN_ACCEL_LAST_TILE is not set,
 * because an interior tile emits nothing.
 *
 * Both buffers must be cache-line aligned: they are handed to a DMA. */
int cnn_accel_compute(cnn_accel *dev, const int8_t *vectors, uint16_t count,
                      unsigned flags, int8_t *results);

#ifdef __cplusplus
}
#endif

#endif /* CNN_ACCEL_H */
