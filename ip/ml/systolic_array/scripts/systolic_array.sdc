#=============================================================================
# systolic_array.sdc - constraints for the systolic matrix-multiply array
#
# Usage from the integrating project:
#
#   set ARRAY_INST [get_cells u_accel/u_array]
#   set ARRAY_CLK  [get_clocks aclk]
#   source ip/ml/systolic_array/scripts/systolic_array.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists ARRAY_INST]} {
    puts "systolic_array.sdc: ARRAY_INST is not set; nothing to constrain"
    return
}

#-----------------------------------------------------------------------------
# The array needs no timing exceptions.
#
# Every path is register to register within one clock, and the longest of them
# is one multiply plus one add - independent of ROWS and COLS. That is the
# property the systolic arrangement exists to provide: enlarging the array
# costs area and latency, never frequency.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# What actually goes wrong, in the order it goes wrong.
#
# 1. The multiply-accumulate was not inferred into a DSP block.
#    Then the period is set by a fabric multiplier and is roughly three times
#    what it should be. Check the DSP count first: it should be exactly
#    ROWS*COLS. Anything less means some elements were built out of LUTs, which
#    on most tools is caused by the accumulator being read somewhere the tool
#    cannot absorb.
#
# 2. w_shift and w_commit fan out to every element.
#    These are the only broadcast signals in the block - ROWS*COLS loads each.
#    A synthesiser will replicate the drivers if it is allowed to; if the
#    weight-load path is what fails, constrain or pipeline the driver outside
#    this block rather than changing the array.
#
# 3. The activation vector and the result vector are wide.
#    ROWS*DATA_WIDTH in and COLS*ACC_WIDTH out - 128 and 512 bits at the
#    default size. They are register to register, but they are long wires on a
#    large device, and they are the paths most sensitive to floorplanning.
#-----------------------------------------------------------------------------
if {[info exists ARRAY_REPORT] && $ARRAY_REPORT} {
    puts "systolic_array: DSP blocks under ${ARRAY_INST}:"
    puts "  [llength [get_cells -quiet -hierarchical -filter \
        {PRIMITIVE_GROUP == ARITHMETIC} ${ARRAY_INST}/*]]"

    report_timing -from [get_pins -quiet ${ARRAY_INST}/w_commit] -max_paths 4
    report_timing -to   [get_pins -quiet ${ARRAY_INST}/res_vector*] -max_paths 4
}

#-----------------------------------------------------------------------------
# Floorplanning note for a large array.
#
# Above roughly 32 by 32 the array benefits from being given a rectangular
# region that matches its logical shape, because the placer otherwise spreads
# the columns and turns the one-hop neighbour wiring - the reason the structure
# is fast - into long routes. On UltraScale+ that means a pblock covering whole
# DSP columns.
#
# Not applied here: the right region depends on the device and on what else is
# in it.
#-----------------------------------------------------------------------------
