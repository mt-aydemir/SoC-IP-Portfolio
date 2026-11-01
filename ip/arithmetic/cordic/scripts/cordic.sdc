#=============================================================================
# cordic.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Usage from the integrating project:
#
#   set CORDIC_INST u_cordic
#   source ip/arithmetic/cordic/scripts/cordic.sdc
#
# CORDIC_INST is the instance's hierarchical name, not a cell object; an
# empty string means the block is the top of the design.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

#-----------------------------------------------------------------------------
# One synchronous state machine in one clock domain, and no exception.
#
# As with the divider, the iteration is not a multicycle path even though an
# operation spans ITERATIONS cycles: x, y and z are rewritten on every edge.
#
# The critical path is the variable arithmetic shift - a mux tree selected by
# the iteration counter - followed by a WIDTH+2 bit adder. An unrolled,
# pipelined CORDIC replaces the variable shift with fixed wiring per stage,
# which is why it runs so much faster; that is a different block.
#-----------------------------------------------------------------------------

if {[info exists CORDIC_INST]} {
    set _c [get_cells -quiet $CORDIC_INST]
    if {[llength $_c] > 0} {
        group_path -name cordic_iteration -through $_c
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis. scripts/run_sta.py sets the clock and the I/O
# environment itself, then sources this file with CORDIC_INST set to "":
# the block as the top of the design, which is how the stage checks that
# every command above runs in OpenSTA.
#-----------------------------------------------------------------------------
