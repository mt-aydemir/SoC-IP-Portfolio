/*=============================================================================
 * cnn_accel_dma.c - AXI DMA transport for a bare-metal Cortex-A53
 *
 * Simple (non scatter-gather) mode: one DMA transfer is one frame, because the
 * DMA asserts TLAST at the end of a transfer and the accelerator delimits its
 * commands with TLAST. That correspondence is the whole reason the driver can
 * be this short.
 *
 * CACHE MAINTENANCE IS THE WHOLE JOB
 *   The A53's data cache is write-back, and the DMA is not coherent with it
 *   on the paths a typical Zynq UltraScale+ design uses - the HP ports are not
 *   snooped unless the design has been built to route them through the CCI,
 *   which costs bandwidth and is usually not done.
 *
 *   So: flush before a transmit, or the DMA reads stale memory; invalidate
 *   before *and* after a receive, or the core reads stale memory. The
 *   invalidate before matters as much as the one after - a dirty line sitting
 *   over the destination buffer would be written back on top of the DMA's data
 *   at an unpredictable moment, and the resulting corruption looks like a
 *   hardware fault rather than a software one.
 *
 *   Every buffer must therefore be cache-line aligned and a whole number of
 *   lines long. Invalidating a partial line either discards a neighbouring
 *   variable's value or leaves part of the result stale, and which of the two
 *   depends on where the linker happened to put things.
 *
 * Build: this file is for the Vitis standalone BSP and is compiled only when
 * CNN_ACCEL_WITH_XAXIDMA is defined, so the rest of the driver stays portable
 * and testable on a host.
 *
 * Copyright (c) 2026 SoC IP Portfolio Contributors
 * SPDX-License-Identifier: Apache-2.0
 *=============================================================================
 */
#include "cnn_accel_dma.h"

#ifdef CNN_ACCEL_WITH_XAXIDMA

#include "xaxidma.h"
#include "xil_cache.h"
#include "xparameters.h"
#include "xstatus.h"

/* Long enough that a real transfer never hits it, short enough that a hung
 * design is reported rather than hanging the application. At 250 MHz this is
 * several milliseconds of polling. */
#ifndef CNN_ACCEL_DMA_POLL_LIMIT
#define CNN_ACCEL_DMA_POLL_LIMIT 100000000u
#endif

static size_t round_up_to_line(size_t bytes)
{
    return (bytes + CNN_ACCEL_CACHE_LINE - 1u) & ~((size_t)CNN_ACCEL_CACHE_LINE - 1u);
}

int cnn_accel_dma_open(cnn_accel_dma *dma, uint16_t device_id)
{
    XAxiDma_Config *config;
    int status;

    if (dma == NULL) {
        return CNN_ACCEL_ERR_ARG;
    }

    config = XAxiDma_LookupConfig(device_id);
    if (config == NULL) {
        return CNN_ACCEL_ERR_TRANSPORT;
    }

    status = XAxiDma_CfgInitialize(&dma->engine, config);
    if (status != XST_SUCCESS) {
        return CNN_ACCEL_ERR_TRANSPORT;
    }

    /* The accelerator is driven by a descriptor chain in the design that wants
     * one; this driver polls, and scatter-gather mode would need a BD ring
     * that a simple transfer does not. Refusing rather than silently
     * misbehaving is the point. */
    if (XAxiDma_HasSg(&dma->engine)) {
        return CNN_ACCEL_ERR_TRANSPORT;
    }

    /* Polling. An interrupt per frame would cost more than the frame does. */
    XAxiDma_IntrDisable(&dma->engine, XAXIDMA_IRQ_ALL_MASK,
                        XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrDisable(&dma->engine, XAXIDMA_IRQ_ALL_MASK,
                        XAXIDMA_DMA_TO_DEVICE);

    dma->rx_buffer = NULL;
    dma->rx_bytes  = 0u;
    return CNN_ACCEL_OK;
}

int cnn_accel_dma_send(void *ctx, const void *frame, size_t bytes)
{
    cnn_accel_dma *dma = (cnn_accel_dma *)ctx;
    uint32_t polls = 0u;
    int status;

    if (((uintptr_t)frame % CNN_ACCEL_CACHE_LINE) != 0u) {
        return CNN_ACCEL_ERR_ARG;
    }

    /* The DMA reads memory, so what the core has written must be visible in
     * it. Rounding the range up to whole cache lines is safe here: flushing a
     * neighbouring line only writes back data that was already correct. */
    Xil_DCacheFlushRange((UINTPTR)frame, round_up_to_line(bytes));

    status = XAxiDma_SimpleTransfer(&dma->engine, (UINTPTR)frame,
                                    (u32)bytes, XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        return CNN_ACCEL_ERR_TRANSPORT;
    }

    while (XAxiDma_Busy(&dma->engine, XAXIDMA_DMA_TO_DEVICE)) {
        if (++polls > CNN_ACCEL_DMA_POLL_LIMIT) {
            return CNN_ACCEL_ERR_TIMEOUT;
        }
    }

    return CNN_ACCEL_OK;
}

int cnn_accel_dma_recv_start(void *ctx, void *buffer, size_t bytes)
{
    cnn_accel_dma *dma = (cnn_accel_dma *)ctx;
    int status;

    if (((uintptr_t)buffer % CNN_ACCEL_CACHE_LINE) != 0u) {
        return CNN_ACCEL_ERR_ARG;
    }

    /* Before the receive, not only after it. A dirty line covering the
     * destination would otherwise be written back over the DMA's data at some
     * later, unpredictable moment. */
    Xil_DCacheInvalidateRange((UINTPTR)buffer, round_up_to_line(bytes));

    status = XAxiDma_SimpleTransfer(&dma->engine, (UINTPTR)buffer,
                                    (u32)bytes, XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        return CNN_ACCEL_ERR_TRANSPORT;
    }

    dma->rx_buffer = buffer;
    dma->rx_bytes  = bytes;
    return CNN_ACCEL_OK;
}

int cnn_accel_dma_recv_wait(void *ctx, size_t *received)
{
    cnn_accel_dma *dma = (cnn_accel_dma *)ctx;
    uint32_t polls = 0u;

    if (dma->rx_buffer == NULL) {
        return CNN_ACCEL_ERR_ARG;
    }

    while (XAxiDma_Busy(&dma->engine, XAXIDMA_DEVICE_TO_DMA)) {
        if (++polls > CNN_ACCEL_DMA_POLL_LIMIT) {
            return CNN_ACCEL_ERR_TIMEOUT;
        }
    }

    /* After the transfer, to drop anything the core speculatively filled while
     * the DMA was writing. */
    Xil_DCacheInvalidateRange((UINTPTR)dma->rx_buffer,
                              round_up_to_line(dma->rx_bytes));

    /* Simple mode completes on TLAST, and the accelerator's frames are exactly
     * as long as the driver asked for, so a short transfer would mean the
     * frame was truncated. The S2MM length register reports what really
     * arrived. */
    *received = (size_t)XAxiDma_ReadReg(dma->engine.RxBdRing[0].ChanBase,
                                        XAXIDMA_BUFFLEN_OFFSET);

    dma->rx_buffer = NULL;
    dma->rx_bytes  = 0u;
    return CNN_ACCEL_OK;
}

void cnn_accel_dma_bind(cnn_accel_transport *transport, cnn_accel_dma *dma)
{
    transport->send       = cnn_accel_dma_send;
    transport->recv_start = cnn_accel_dma_recv_start;
    transport->recv_wait  = cnn_accel_dma_recv_wait;
    transport->ctx        = dma;
}

#endif /* CNN_ACCEL_WITH_XAXIDMA */
