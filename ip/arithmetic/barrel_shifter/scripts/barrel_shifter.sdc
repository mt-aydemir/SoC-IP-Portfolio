#=============================================================================
# barrel_shifter.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the clock definition and the
# I/O environment. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Usage from the integrating project:
#
#   set BARREL_SHIFTER_INST u_shift
#   source ip/arithmetic/barrel_shifter/scripts/barrel_shifter.sdc
#
# BARREL_SHIFTER_INST is the instance's hierarchical name, not a cell object; an
# empty string means the block is the top of the design.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

#-----------------------------------------------------------------------------
# The block is purely combinational: no clock, no state, and no timing
# exception of its own.
#
# Its delay is $clog2(WIDTH) multiplexer levels plus the operation select, so
# it grows logarithmically with the data width and linearly with nothing. That
# makes it cheap at wide widths and still several levels of logic at any
# width: a shifter in series with an adder in one cycle is a classic critical
# path.
#
# Two things an integrator should know:
#
#   * The `operation` port selects the final multiplexer, so its arrival time
#     adds directly to the result's. Drive it from a register or a constant,
#     not from a wide combinational decode in the same cycle.
#
#   * The `amount` port drives every stage of the tree, so it has the highest
#     fanout of any input and is frequently the latest-arriving one.
#
# The path group below makes the shifter reportable by name rather than as an
# anonymous critical path in the datapath.
#-----------------------------------------------------------------------------

if {[info exists BARREL_SHIFTER_INST]} {
    set _c [get_cells -quiet $BARREL_SHIFTER_INST]
    if {[llength $_c] > 0} {
        group_path -name barrel_shifter_tree -through $_c
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis.
#
# The block is registered with NO_STA, so scripts/run_sta.py never times it on
# its own: with no clock there is no setup or hold check to make, and a report
# of "no paths found" is not evidence of anything.
#-----------------------------------------------------------------------------
