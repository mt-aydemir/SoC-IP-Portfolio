#=============================================================================
# subtractor.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the clock definition and the
# I/O environment. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Usage from the integrating project:
#
#   set SUBTRACTOR_INST u_sub
#   source ip/arithmetic/subtractor/scripts/subtractor.sdc
#
# SUBTRACTOR_INST is the instance's hierarchical name, not a cell object; an
# empty string means the block is the top of the design.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

#-----------------------------------------------------------------------------
# The block is purely combinational: no clock, no state, and no timing
# exception of its own. Every path through it belongs to a register-to-register
# path owned by the surrounding pipeline, and the default single-cycle analysis
# of that path is the correct one.
#
# Its delay is one adder carry chain plus the saturation multiplexer, so it is
# marginally slower than the adder at the same width. The path group below
# makes that visible under a recognisable name rather than as an anonymous
# critical path in the datapath.
#-----------------------------------------------------------------------------

if {[info exists SUBTRACTOR_INST]} {
    set _c [get_cells -quiet $SUBTRACTOR_INST]
    if {[llength $_c] > 0} {
        group_path -name subtractor_borrow_chain -through $_c
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis.
#
# The block is registered with NO_STA, so scripts/run_sta.py never times it on
# its own: with no clock there is no setup or hold check to make, and a report
# of "no paths found" is not evidence of anything.
#-----------------------------------------------------------------------------
