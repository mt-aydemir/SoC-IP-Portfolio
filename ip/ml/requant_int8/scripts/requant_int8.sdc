#=============================================================================
# requant_int8.sdc - constraints for the requantisation stage
#
# Usage from the integrating project:
#
#   set REQUANT_INST u_requant
#   source ip/ml/requant_int8/scripts/requant_int8.sdc
#
# REQUANT_INST is the instance's hierarchical name, not a cell object, and an empty
# string means the block is the top of the design. Only commands common to
# OpenSTA, Synopsys tools and Vivado are used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists REQUANT_INST]} {
    puts "requant_int8.sdc: REQUANT_INST is not set; nothing to constrain"
    return
}
set _p [expr {$REQUANT_INST eq "" ? "" : "$REQUANT_INST/"}]

#-----------------------------------------------------------------------------
# The block needs no timing exceptions.
#
# It is a three-stage pipeline in one clock domain with a register on every
# output. This file exists for the notes below.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# The critical path is stage 2, and it is a multiply.
#
# A signed 33-bit by unsigned 24-bit product is one DSP block on most FPGA
# targets and roughly 2 ns of it. If the design misses its period, this is the
# first path to look at, and the cheapest fix is to split stage 2 across two
# registers - one extra cycle of latency, no change to the interface contract
# beyond the LATENCY constant the consumer aligns to.
#
# The second-longest path is stage 3: a variable shift by up to SHIFT_WIDTH
# bits followed by two comparisons. A barrel shifter of that width is around
# six levels of logic and is usually comfortable, but it is what will limit the
# design if the multiply has been retimed away. Without carry chains it is the
# longest path outright, which is why the generic-library run is timed at
# 6.5 ns, so the paths leaving the product register are a group of their own.
#-----------------------------------------------------------------------------
set _nets [get_nets -quiet ${_p}product_s2*]
if {[llength $_nets] > 0} {
    group_path -name requant_stage3 -through $_nets
}

#-----------------------------------------------------------------------------
# Parameter fanout.
#
# bias, mult, shift, out_zero_point, out_min and out_max come from registers
# that change once per job rather than once per beat. They are not constant, so
# a false path would be wrong; but they are quiet, and if the design is close
# on those paths a multicycle constraint against the job rate - not the beat
# rate - is legitimate. It is deliberately not applied here, because the job
# rate is a property of the integrating design rather than of this block.
#-----------------------------------------------------------------------------
