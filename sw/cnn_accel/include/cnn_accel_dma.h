/*=============================================================================
 * cnn_accel_dma.h - AXI DMA transport for a bare-metal Cortex-A53
 *
 * Compiled only when CNN_ACCEL_WITH_XAXIDMA is defined, which is what keeps
 * the rest of the driver free of Xilinx headers and testable on a host.
 *
 * Copyright (c) 2026 SoC IP Portfolio Contributors
 * SPDX-License-Identifier: Apache-2.0
 *=============================================================================
 */
#ifndef CNN_ACCEL_DMA_H
#define CNN_ACCEL_DMA_H

#include "cnn_accel.h"

#ifdef CNN_ACCEL_WITH_XAXIDMA

#include "xaxidma.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cnn_accel_dma {
    XAxiDma  engine;
    void    *rx_buffer;
    size_t   rx_bytes;
} cnn_accel_dma;

/* Initialise the engine and check it is a simple-mode instance. */
int cnn_accel_dma_open(cnn_accel_dma *dma, uint16_t device_id);

/* Fill in a transport that talks to this engine. */
void cnn_accel_dma_bind(cnn_accel_transport *transport, cnn_accel_dma *dma);

int cnn_accel_dma_send(void *ctx, const void *frame, size_t bytes);
int cnn_accel_dma_recv_start(void *ctx, void *buffer, size_t bytes);
int cnn_accel_dma_recv_wait(void *ctx, size_t *received);

#ifdef __cplusplus
}
#endif

#endif /* CNN_ACCEL_WITH_XAXIDMA */

#endif /* CNN_ACCEL_DMA_H */
