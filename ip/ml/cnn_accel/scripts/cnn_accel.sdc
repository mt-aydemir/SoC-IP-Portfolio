#=============================================================================
# cnn_accel.sdc - constraints for the CNN inference accelerator
#
# Usage from the integrating project:
#
#   set ACCEL_INST u_accel
#   source ip/ml/cnn_accel/scripts/cnn_accel.sdc
#
# ACCEL_INST is the instance's hierarchical name, not a cell object, and an empty
# string means the block is the top of the design. Only commands common to
# OpenSTA, Synopsys tools and Vivado are used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists ACCEL_INST]} {
    puts "cnn_accel.sdc: ACCEL_INST is not set; nothing to constrain"
    return
}
set _p [expr {$ACCEL_INST eq "" ? "" : "$ACCEL_INST/"}]

#-----------------------------------------------------------------------------
# The accelerator needs no timing exceptions.
#
# It is one clock domain end to end - stream in, array, accumulator,
# requantiser, stream out - and every path is register to register. The block
# it is instantiated in is where the exceptions live, if any: the clock
# crossing to the processing system's stream, and the interrupt.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# The interrupt leaves this clock domain.
#
# irq is a one-cycle pulse in the accelerator's clock. Routed to the PS it
# crosses into whatever domain the interrupt controller is in, and the correct
# treatment is a cdc_pulse_sync in the integrating design, not a false path
# here. The synchroniser's own fragment, cdc_pulse_sync.sdc, then constrains
# the crossing.
#
# Nothing is applied here, because a false path on the interrupt is exactly the
# kind of constraint that hides a real metastability problem.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# What to look at when it does not close.
#
# 1. The array, and whether it went into DSP blocks at all. Expect ARRAY_N**2
#    for the array plus about two per requantiser. Substantially fewer means
#    some multiplies were built out of fabric, which costs roughly a factor of
#    three in period. See ip/ml/systolic_array/scripts/systolic_array.sdc.
#
# 2. s_axis_tready. It is combinational from the credit comparison, which
#    reads the output FIFO level and the in-flight counter. That is a short
#    path, but it reaches the DMA, so on a large device it can become the
#    longest route in the design rather than the deepest logic. A register
#    slice between the DMA and the accelerator fixes it at the cost of one
#    cycle of latency and costs nothing in throughput.
#
# 3. The accumulator buffer. ARRAY_N*ACC_WIDTH bits wide - 512 at the default
#    size - so it is several block RAMs in parallel and the adder in front of
#    the write port sees all of them. If this is the failure, pipelining the
#    add costs one cycle of latency and one more entry of output buffer.
#
# Items 2 and 3 are reported as path groups of their own.
#-----------------------------------------------------------------------------
set _nets [get_nets -quiet ${_p}s_axis_tready]
if {[llength $_nets] > 0} {
    group_path -name cnn_accel_admission -through $_nets
}
set _nets [get_nets -quiet ${_p}acc_sum*]
if {[llength $_nets] > 0} {
    group_path -name cnn_accel_accumulate -through $_nets
}

#-----------------------------------------------------------------------------
# Stream interface timing, if the DMA is in another clock domain.
#
# The accelerator is single-clock and does not cross domains itself. Put an
# fifo_async on each stream outside it rather than constraining across the
# boundary here; the portfolio's integration guide covers the rules.
#-----------------------------------------------------------------------------
