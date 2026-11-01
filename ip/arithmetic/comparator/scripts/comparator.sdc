#=============================================================================
# comparator.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the clock definition and the
# I/O environment. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Usage from the integrating project:
#
#   set COMPARATOR_INST u_limit
#   source ip/arithmetic/comparator/scripts/comparator.sdc
#
# COMPARATOR_INST is the instance's hierarchical name, not a cell object; an
# empty string means the block is the top of the design.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

#-----------------------------------------------------------------------------
# The block is purely combinational: no clock, no state, and no timing
# exception of its own. Every path through it belongs to a register-to-register
# path owned by the surrounding pipeline.
#
# Its delay is one full-width subtraction plus a few gates, so it grows with
# WIDTH exactly as the adder's does. A comparator feeding a control decision
# is a common critical path precisely because the decision is often needed
# early in the cycle; the path group below makes it reportable by name.
#-----------------------------------------------------------------------------

if {[info exists COMPARATOR_INST]} {
    set _c [get_cells -quiet $COMPARATOR_INST]
    if {[llength $_c] > 0} {
        group_path -name comparator_decision -through $_c
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis.
#
# The block is registered with NO_STA, so scripts/run_sta.py never times it on
# its own: with no clock there is no setup or hold check to make, and a report
# of "no paths found" is not evidence of anything.
#-----------------------------------------------------------------------------
