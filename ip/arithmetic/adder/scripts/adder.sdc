#=============================================================================
# adder.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the clock definition and the
# I/O environment.
#
# Usage from the integrating project:
#
#   set ADDER_INST [get_cells u_add]
#   source ip/arithmetic/adder/scripts/adder.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

#-----------------------------------------------------------------------------
# The block is purely combinational. It has no clock, no state and no timing
# exception of its own: every path through it is part of a register-to-register
# path owned by the surrounding pipeline, and the default single-cycle analysis
# of that path is the correct one.
#
# There is therefore nothing to constrain here, and this file exists to say so
# explicitly rather than to leave an integrator wondering what is missing.
#
# What an integrator does need to know is that the carry chain is the longest
# path in the block and that its delay grows with WIDTH. At large widths it is
# frequently the critical path of the stage containing it. The path group below
# makes it reportable under a recognisable name instead of turning up as an
# anonymous critical path somewhere in the datapath.
#-----------------------------------------------------------------------------

if {[info exists ADDER_INST]} {
    if {[sizeof_collection [get_cells -quiet $ADDER_INST]] > 0} {
        group_path -name adder_carry_chain -through [get_cells $ADDER_INST]
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis.
#
# The block is registered with NO_STA, so scripts/run_sta.py never times it on
# its own: with no clock there is no setup or hold check to make, and a report
# of "no paths found" is not evidence of anything. Its timing is covered by the
# sequential blocks that instantiate it - alu, subtractor and mac among them.
#-----------------------------------------------------------------------------
