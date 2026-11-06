#=============================================================================
# systolic_pe.sdc - constraints for one processing element
#
# Usage from the integrating project:
#
#   set PE_INST u_pe
#   source ip/ml/systolic_pe/scripts/systolic_pe.sdc
#
# PE_INST is the instance's hierarchical name, not a cell object, and an empty
# string means the block is the top of the design. Only commands common to
# OpenSTA, Synopsys tools and Vivado are used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists PE_INST]} {
    puts "systolic_pe.sdc: PE_INST is not set; nothing to constrain"
    return
}
set _p [expr {$PE_INST eq "" ? "" : "$PE_INST/"}]

#-----------------------------------------------------------------------------
# The element needs no timing exceptions.
#
# Every path is register to register within one clock, and every output is a
# register output. That is the property the systolic arrangement exists to
# provide: the critical path of an array of any size is one multiply-add, not
# a function of the array dimensions.
#
# This file exists for the notes below rather than for constraints.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# The path that actually closes timing.
#
# psum_in -> psum_out carries the adder, and a_in -> psum_out carries the
# multiplier and then the adder. On an FPGA both are absorbed into a single
# DSP block, at which point the achievable period is a property of the DSP,
# not of the surrounding logic - around 2 ns on UltraScale+ speed grade -2 with
# the internal pipeline registers used.
#
# Reporting them separately is worth doing once after the first place and
# route of a new array size, because it is the quickest way to see whether the
# multiply-accumulate was inferred into a DSP block at all or was built out of
# fabric, which costs roughly a factor of three in period.
#-----------------------------------------------------------------------------
set _nets [get_nets -quiet ${_p}psum_in*]
if {[llength $_nets] > 0} {
    group_path -name systolic_pe_accumulate -through $_nets
}

#-----------------------------------------------------------------------------
# w_shift and w_commit are broadcast to every element in the array.
#
# They are the only high-fanout signals in the design, and they are the ones a
# synthesiser will want to replicate. Nothing here forces that, because the
# right amount of replication depends on the array size; if the weight-load
# path is what fails timing, constrain the driver rather than the elements.
#-----------------------------------------------------------------------------
