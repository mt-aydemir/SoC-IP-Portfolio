#=============================================================================
# divider.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Usage from the integrating project:
#
#   set DIVIDER_INST u_div
#   source ip/arithmetic/divider/scripts/divider.sdc
#
# DIVIDER_INST is the instance's hierarchical name, not a cell object; an
# empty string means the block is the top of the design.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

#-----------------------------------------------------------------------------
# One synchronous state machine in one clock domain.
#
# It is tempting to declare the iteration datapath a multicycle path, since a
# division takes WIDTH cycles. It is not one, and must not be constrained as
# one: every iteration commits a new remainder on every edge, so the trial
# subtraction is a genuine single-cycle path. The default analysis is correct.
#
# The output negation that applies the signs is combinational from the
# registers to the result ports. Its delay belongs to whatever the sink does
# with the result in the same cycle; the path group makes it visible.
#-----------------------------------------------------------------------------

if {[info exists DIVIDER_INST]} {
    set _c [get_cells -quiet $DIVIDER_INST]
    if {[llength $_c] > 0} {
        group_path -name divider_iteration -through $_c
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis. scripts/run_sta.py sets the clock and the I/O
# environment itself, then sources this file with DIVIDER_INST set to "":
# the block as the top of the design, which is how the stage checks that
# every command above runs in OpenSTA.
#-----------------------------------------------------------------------------
