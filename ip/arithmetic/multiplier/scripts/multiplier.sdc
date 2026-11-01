#=============================================================================
# multiplier.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment.
#
# Usage from the integrating project:
#
#   set MULTIPLIER_INST [get_cells u_mul]
#   set MULTIPLIER_CLK  [get_clocks clk_core]
#   source ip/arithmetic/multiplier/scripts/multiplier.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists MULTIPLIER_CLK]} {
    puts "multiplier.sdc: MULTIPLIER_CLK is not set; using the design's first clock"
    set MULTIPLIER_CLK [lindex [all_clocks] 0]
}

#-----------------------------------------------------------------------------
# The block is a single synchronous pipeline in one clock domain. It contains
# no clock domain crossing, no multi-cycle path and no combinational feedback,
# so it needs no timing exceptions: the default single-cycle analysis is the
# correct one.
#
# What it does need is retiming. Every pipeline register is deliberately at
# the output, because synthesis distributes them through the partial-product
# tree far better than hand placement can. Without a retiming pass the
# registers do nothing for the critical path and the block will miss timing at
# any width worth pipelining.
#
# Retiming is enabled in the synthesis tool, not in SDC, so this file cannot
# do it for the integrator. The path group below at least makes the array
# reportable under a recognisable name.
#-----------------------------------------------------------------------------

if {[info exists MULTIPLIER_INST]} {
    if {[sizeof_collection [get_cells -quiet $MULTIPLIER_INST]] > 0} {
        group_path -name multiplier_array -through [get_cells $MULTIPLIER_INST]
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis, used by scripts/run_sta.py when the block is timed on
# its own. The integrating project overrides all of this.
#
# Inputs and outputs are given 20% of the period, which leaves the internal
# path the remaining 60% and keeps the reported slack a statement about the
# block rather than about an arbitrary I/O budget.
#-----------------------------------------------------------------------------
if {![info exists MULTIPLIER_INST]} {
    set _period [get_property $MULTIPLIER_CLK period]
    set _inputs [remove_from_collection [all_inputs] [get_ports -quiet clk]]

    if {[sizeof_collection $_inputs] > 0} {
        set_input_delay -clock $MULTIPLIER_CLK [expr {$_period * 0.20}] $_inputs
    }
    if {[sizeof_collection [all_outputs]] > 0} {
        set_output_delay -clock $MULTIPLIER_CLK [expr {$_period * 0.20}] [all_outputs]
    }
}
