#=============================================================================
# cnn_accel.sdc - constraints for the CNN inference accelerator
#
# Usage from the integrating project:
#
#   set ACCEL_INST [get_cells design_1_i/cnn_accel_0/inst]
#   set ACCEL_CLK  [get_clocks clk_pl_0]
#   source ip/ml/cnn_accel/scripts/cnn_accel.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists ACCEL_INST]} {
    puts "cnn_accel.sdc: ACCEL_INST is not set; nothing to constrain"
    return
}

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
# here. If the integration does use a synchroniser, constrain it there:
#
#   set_max_delay -datapath_only [get_property PERIOD $ACCEL_CLK] \
#       -from [get_pins ${ACCEL_INST}/irq_reg/C] -to [get_pins .../D]
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
#-----------------------------------------------------------------------------
if {[info exists ACCEL_REPORT] && $ACCEL_REPORT} {
    report_timing -to   [get_pins -quiet ${ACCEL_INST}/s_axis_tready] -max_paths 4
    report_timing -from [get_pins -quiet ${ACCEL_INST}/u_accumulator/*] -max_paths 4
}

#-----------------------------------------------------------------------------
# Stream interface timing, if the DMA is in another clock domain.
#
# The accelerator is single-clock and does not cross domains itself. Put an
# fifo_async on each stream outside it rather than constraining across the
# boundary here; the portfolio's integration guide covers the rules.
#-----------------------------------------------------------------------------
