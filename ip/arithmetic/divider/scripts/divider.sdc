#=============================================================================
# divider.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment.
#
# Usage from the integrating project:
#
#   set DIVIDER_INST [get_cells u_div]
#   set DIVIDER_CLK  [get_clocks clk_core]
#   source ip/arithmetic/divider/scripts/divider.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists DIVIDER_CLK]} {
    puts "divider.sdc: DIVIDER_CLK is not set; using the design's first clock"
    set DIVIDER_CLK [lindex [all_clocks] 0]
}

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
    if {[sizeof_collection [get_cells -quiet $DIVIDER_INST]] > 0} {
        group_path -name divider_iteration -through [get_cells $DIVIDER_INST]
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis, used by scripts/run_sta.py when the block is timed on
# its own. The integrating project overrides all of this.
#-----------------------------------------------------------------------------
if {![info exists DIVIDER_INST]} {
    set _period [get_property $DIVIDER_CLK period]
    set _inputs [remove_from_collection [all_inputs] [get_ports -quiet clk]]

    if {[sizeof_collection $_inputs] > 0} {
        set_input_delay -clock $DIVIDER_CLK [expr {$_period * 0.20}] $_inputs
    }
    if {[sizeof_collection [all_outputs]] > 0} {
        set_output_delay -clock $DIVIDER_CLK [expr {$_period * 0.20}] [all_outputs]
    }
}
