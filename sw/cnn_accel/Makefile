#=============================================================================
# sw/cnn_accel/Makefile
#
# Two targets, deliberately independent:
#
#   make test    builds and runs the host self-test with the system compiler.
#                No Xilinx headers, no board. This is the target that runs in
#                CI and the one to run after changing the driver.
#
#   make app     cross-compiles the bare-metal demonstration against a Vitis
#                standalone BSP. Needs BSP to point at the generated BSP
#                directory, which is where the AXI DMA driver and xparameters.h
#                come from.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

BUILD     ?= build
ARRAY_N   ?= 16
ACC_DEPTH ?= 256

GEOMETRY := -DCNN_ACCEL_ARRAY_N=$(ARRAY_N) -DCNN_ACCEL_ACC_DEPTH=$(ACC_DEPTH)

#-----------------------------------------------------------------------------
# Host self-test
#-----------------------------------------------------------------------------
HOST_CC     ?= cc
HOST_CFLAGS ?= -std=c11 -O2 -g -Wall -Wextra -Wpedantic -Wshadow \
               -Wconversion -Wsign-conversion
HOST_INC    := -Iinclude -Itest

HOST_SRC := src/cnn_accel.c \
            src/cnn_accel_quant.c \
            src/cnn_accel_conv2d.c \
            test/cnn_accel_model.c \
            test/test_host.c

.PHONY: all test app clean

all: test

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/test_host: $(HOST_SRC) | $(BUILD)
	$(HOST_CC) $(HOST_CFLAGS) $(GEOMETRY) $(HOST_INC) $(HOST_SRC) -lm -o $@

test: $(BUILD)/test_host
	$(BUILD)/test_host

#-----------------------------------------------------------------------------
# Bare-metal application
#
# BSP is the standalone BSP Vitis generated for the psu_cortexa53_0 domain of
# the hardware design in fpga/zynq_ultrascale. It supplies xparameters.h, the
# AXI DMA driver, the cache operations and the linker script.
#-----------------------------------------------------------------------------
CROSS  ?= aarch64-none-elf-
CC     := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
SIZE    := $(CROSS)size

BSP    ?=
LDSCRIPT ?= app/lscript.ld

APP_CFLAGS ?= -std=c11 -O2 -g -Wall -Wextra -mcpu=cortex-a53 \
              -DCNN_ACCEL_WITH_XAXIDMA
APP_INC    := -Iinclude $(if $(BSP),-I$(BSP)/include,)
APP_LDFLAGS := -Wl,-T -Wl,$(LDSCRIPT) $(if $(BSP),-L$(BSP)/lib,) \
               -Wl,--start-group,-lxil,-lgcc,-lc,--end-group

APP_SRC := src/cnn_accel.c \
           src/cnn_accel_quant.c \
           src/cnn_accel_conv2d.c \
           src/cnn_accel_dma.c \
           app/main.c

app: $(BUILD)/cnn_accel_demo.elf

$(BUILD)/cnn_accel_demo.elf: $(APP_SRC) | $(BUILD)
	@if [ -z "$(BSP)" ]; then \
	    echo "BSP is not set."; \
	    echo "Point it at the Vitis standalone BSP for the A53 domain, e.g."; \
	    echo "  make app BSP=../../fpga/zynq_ultrascale/workspace/zcu104/psu_cortexa53_0/standalone_domain/bsp/psu_cortexa53_0"; \
	    exit 1; \
	fi
	$(CC) $(APP_CFLAGS) $(GEOMETRY) $(APP_INC) $(APP_SRC) \
	      $(APP_LDFLAGS) -lm -o $@
	$(SIZE) $@

clean:
	rm -rf $(BUILD)
