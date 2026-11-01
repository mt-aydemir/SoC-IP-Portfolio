#=============================================================================
# alu.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the clock definition and the
# I/O environment. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Usage from the integrating project:
#
#   set ALU_INST u_alu
#   source ip/arithmetic/alu/scripts/alu.sdc
#
# ALU_INST is the instance's hierarchical name, not a cell object; an
# empty string means the block is the top of the design.
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
    set _prefix [expr {$ALU_INST eq "" ? "" : "$ALU_INST/"}]
    foreach {_group _cell} {alu_adder u_adder alu_shifter u_shifter} {
        set _c [get_cells -quiet ${_prefix}${_cell}]
        if {[llength $_c] > 0} {
            group_path -name $_group -through $_c
        }
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis.
#
# The block is registered with NO_STA, so scripts/run_sta.py never times it on
# its own: with no clock there is no setup or hold check to make, and a report
# of "no paths found" is not evidence of anything.
#-----------------------------------------------------------------------------
