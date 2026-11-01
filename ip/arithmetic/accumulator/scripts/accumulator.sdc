#=============================================================================
# accumulator.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment.
#
# Usage from the integrating project:
#
#   set ACCUMULATOR_INST [get_cells u_acc]
#   set ACCUMULATOR_CLK  [get_clocks clk_core]
#   source ip/arithmetic/accumulator/scripts/accumulator.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists ACCUMULATOR_CLK]} {
    puts "accumulator.sdc: ACCUMULATOR_CLK is not set; using the design's first clock"
    set ACCUMULATOR_CLK [lindex [all_clocks] 0]
}

#-----------------------------------------------------------------------------
# One synchronous register in one clock domain: no crossing, no multi-cycle
# path, no combinational feedback, and therefore no timing exception. The
# default single-cycle analysis is the correct one.
#
# The block's critical path is entirely inside the register's data path: a
# full ACC_WIDTH carry chain, then the saturation decision, then the
# clear/load/enable priority multiplexing. All of it scales with ACC_WIDTH,
# so this is the block whose slack moves when the total is widened.
#
# A loop worth naming: acc_out feeds the adder that produces its own next
# value. That is an ordinary register-to-register path, not a combinational
# loop, but it means the accumulator cannot be retimed - there is nowhere to
# move the register to. A wide accumulator that misses timing has to be
# restructured by the integrator (for example into two half-width
# accumulations combined later), not fixed with constraints.
#-----------------------------------------------------------------------------

if {[info exists ACCUMULATOR_INST]} {
    if {[sizeof_collection [get_cells -quiet $ACCUMULATOR_INST]] > 0} {
        group_path -name accumulator_feedback \
                   -through [get_cells $ACCUMULATOR_INST]
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis, used by scripts/run_sta.py when the block is timed on
# its own. The integrating project overrides all of this.
#-----------------------------------------------------------------------------
if {![info exists ACCUMULATOR_INST]} {
    set _period [get_property $ACCUMULATOR_CLK period]
    set _inputs [remove_from_collection [all_inputs] [get_ports -quiet clk]]

    if {[sizeof_collection $_inputs] > 0} {
        set_input_delay -clock $ACCUMULATOR_CLK [expr {$_period * 0.20}] $_inputs
    }
    if {[sizeof_collection [all_outputs]] > 0} {
        set_output_delay -clock $ACCUMULATOR_CLK [expr {$_period * 0.20}] [all_outputs]
    }
}
