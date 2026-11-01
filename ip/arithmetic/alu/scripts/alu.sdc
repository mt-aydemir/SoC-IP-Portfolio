#=============================================================================
# alu.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the clock definition and the
# I/O environment.
#
# Usage from the integrating project:
#
#   set ALU_INST [get_cells u_alu]
#   source ip/arithmetic/alu/scripts/alu.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

#-----------------------------------------------------------------------------
# The block is purely combinational: no clock, no state, and no timing
# exception of its own.
#
# It has two candidate critical paths, through the shared adder and through
# the shared barrel shifter, which meet at the result multiplexer. The flags
# then add a zero-detect over the full result, which makes flag_zero the
# latest-arriving output of the block. Reporting the two halves separately
# tells an integrator which one to attack.
#-----------------------------------------------------------------------------

if {[info exists ALU_INST]} {
    if {[sizeof_collection [get_cells -quiet $ALU_INST]] > 0} {
        group_path -name alu_adder   -through [get_cells -quiet ${ALU_INST}/u_adder]
        group_path -name alu_shifter -through [get_cells -quiet ${ALU_INST}/u_shifter]
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis.
#
# The block is registered with NO_STA, so scripts/run_sta.py never times it on
# its own: with no clock there is no setup or hold check to make, and a report
# of "no paths found" is not evidence of anything.
#-----------------------------------------------------------------------------
