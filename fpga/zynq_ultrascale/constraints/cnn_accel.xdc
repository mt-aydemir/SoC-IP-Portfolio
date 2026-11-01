#=============================================================================
# cnn_accel.xdc - implementation constraints for the reference design
#
# The clock is created by the processing system IP, so there is no
# create_clock here and there should not be one: a second definition of a clock
# the PS already constrains is one of the more effective ways to make a design
# that meets timing in the report and fails on the board.
#
# What is here is the part the tools cannot infer.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

#-----------------------------------------------------------------------------
# Status outputs.
#
# error and busy are brought to ports for probing during bring-up. They are
# not sampled by anything, and constraining them would only produce failing
# paths to unconstrained pads.
#-----------------------------------------------------------------------------
set_false_path -to [get_ports -quiet cnn_accel_error]
set_false_path -to [get_ports -quiet cnn_accel_busy]

#-----------------------------------------------------------------------------
# Floorplanning.
#
# Deliberately not applied, and here is the reasoning rather than the pblock.
#
# A 16x16 array is 256 DSP blocks. On a ZU7EV that is under a sixth of the
# device and the placer has no trouble with it: the array's wiring is entirely
# nearest-neighbour, which is exactly the pattern a placer handles well when it
# has room.
#
# It stops being true at 32x32 and above. 1024 DSPs span several DSP columns,
# the placer starts spreading the array's rows to reach them, and the one-hop
# neighbour routes - the whole reason the structure is fast - turn into long
# ones. At that size, constrain the array to a rectangular region whose shape
# matches its logical shape:
#
#   create_pblock pblock_array
#   add_cells_to_pblock [get_pblocks pblock_array] \
#       [get_cells -hierarchical -filter {NAME =~ "*u_array/g_row*"}]
#   resize_pblock [get_pblocks pblock_array] -add {CLOCKREGION_X2Y0:CLOCKREGION_X3Y3}
#
# Choosing the region needs the device and the rest of the design, which is why
# it is a comment rather than a constraint.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# DSP inference check.
#
# Not a constraint - a report, and the first thing to look at if the design
# misses its period. The array should use exactly ARRAY_N**2 DSP blocks, plus
# about two per requantiser. Substantially fewer means some of the
# multiply-accumulates were built out of fabric, which costs roughly a factor
# of three in achievable period, and no amount of constraining will recover it.
#
# Run after opening the implemented design:
#
#   report_utilization -cells [get_cells -hierarchical -filter {NAME =~ "*cnn_accel_0*"}]
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# If the design does not close timing, in the order worth trying.
#
# 1. Check the DSP count, as above.
#
# 2. Look at s_axis_tready. It is combinational from the credit comparison,
#    which reads the output FIFO level and the in-flight counter, and it
#    reaches the DMA. Short logic, potentially long route. An AXI4-Stream
#    register slice between the DMA and the accelerator costs one cycle of
#    latency, nothing in throughput, and is the cheapest fix.
#
# 3. Look at the accumulator buffer's write path: ARRAY_N*ACC_WIDTH bits of
#    adder in front of several block RAMs in parallel. Pipelining that add
#    costs one cycle of latency and one more entry of output buffer.
#
# 4. Only then lower the PL clock. 250 MHz on a -2 part is not aggressive, and
#    a design that needs 150 MHz to close has something structurally wrong with
#    it rather than something that needs a slower clock.
#-----------------------------------------------------------------------------
