#=============================================================================
# cordic.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment.
#
# Usage from the integrating project:
#
#   set CORDIC_INST [get_cells u_cordic]
#   set CORDIC_CLK  [get_clocks clk_core]
#   source ip/arithmetic/cordic/scripts/cordic.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists CORDIC_CLK]} {
    puts "cordic.sdc: CORDIC_CLK is not set; using the design's first clock"
    set CORDIC_CLK [lindex [all_clocks] 0]
}

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
    if {[sizeof_collection [get_cells -quiet $CORDIC_INST]] > 0} {
        group_path -name cordic_iteration -through [get_cells $CORDIC_INST]
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis, used by scripts/run_sta.py when the block is timed on
# its own. The integrating project overrides all of this.
#-----------------------------------------------------------------------------
if {![info exists CORDIC_INST]} {
    set _period [get_property $CORDIC_CLK period]
    set _inputs [remove_from_collection [all_inputs] [get_ports -quiet clk]]

    if {[sizeof_collection $_inputs] > 0} {
        set_input_delay -clock $CORDIC_CLK [expr {$_period * 0.20}] $_inputs
    }
    if {[sizeof_collection [all_outputs]] > 0} {
        set_output_delay -clock $CORDIC_CLK [expr {$_period * 0.20}] [all_outputs]
    }
}
