#=============================================================================
# mac.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment.
#
# Usage from the integrating project:
#
#   set MAC_INST [get_cells u_mac]
#   set MAC_CLK  [get_clocks clk_core]
#   source ip/arithmetic/mac/scripts/mac.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists MAC_CLK]} {
    puts "mac.sdc: MAC_CLK is not set; using the design's first clock"
    set MAC_CLK [lindex [all_clocks] 0]
}

#-----------------------------------------------------------------------------
# One synchronous pipeline in one clock domain: no crossing, no multi-cycle
# path, no combinational feedback, and therefore no timing exception. The
# default single-cycle analysis is the correct one.
#
# The block has two distinct critical paths, and they respond to completely
# different fixes:
#
#   multiplier array   Can be improved by retiming, which needs the
#                      multiplier's LATENCY raised so there are registers to
#                      retime. Enabled in the synthesis tool, not here.
#
#   accumulator loop   Cannot be retimed at all: the accumulator's register
#                      feeds the adder that computes its own next value, so
#                      there is nowhere to move a register to. A wide
#                      accumulator that misses timing has to be restructured
#                      by the integrator - for example into two half-width
#                      accumulations combined after the frame - not fixed with
#                      constraints or extra pipeline stages.
#
# Reporting them separately is therefore worth the two path groups: knowing
# which of the two is critical tells the integrator which fix to reach for.
#-----------------------------------------------------------------------------

if {[info exists MAC_INST]} {
    if {[sizeof_collection [get_cells -quiet $MAC_INST]] > 0} {
        group_path -name mac_multiplier \
                   -through [get_cells -quiet ${MAC_INST}/u_multiplier]
        group_path -name mac_accumulator \
                   -through [get_cells -quiet ${MAC_INST}/u_accumulator]
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis, used by scripts/run_sta.py when the block is timed on
# its own. The integrating project overrides all of this.
#-----------------------------------------------------------------------------
if {![info exists MAC_INST]} {
    set _period [get_property $MAC_CLK period]
    set _inputs [remove_from_collection [all_inputs] [get_ports -quiet clk]]

    if {[sizeof_collection $_inputs] > 0} {
        set_input_delay -clock $MAC_CLK [expr {$_period * 0.20}] $_inputs
    }
    if {[sizeof_collection [all_outputs]] > 0} {
        set_output_delay -clock $MAC_CLK [expr {$_period * 0.20}] [all_outputs]
    }
}
