#=============================================================================
# template_ip.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# I/O environment.
#
# Usage from the integrating project:
#
#   set TEMPLATE_IP_INST  [get_cells u_stage]
#   set TEMPLATE_IP_CLK   [get_clocks clk_core]
#   source ip/<category>/template_ip/scripts/template_ip.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists TEMPLATE_IP_CLK]} {
    puts "template_ip.sdc: TEMPLATE_IP_CLK is not set; using the design's first clock"
    set TEMPLATE_IP_CLK [lindex [all_clocks] 0]
}

#-----------------------------------------------------------------------------
# The block is a single synchronous stage in one clock domain. It contains no
# clock domain crossing, no multi-cycle path and no combinational feedback, so
# it needs no exceptions: the default single-cycle analysis is correct.
#
# The one thing an integrator must be aware of is the combinational path from
# m_ready to s_ready. It is declared here so that the path shows up in reports
# under a recognisable name rather than as an anonymous critical path.
#-----------------------------------------------------------------------------

if {[info exists TEMPLATE_IP_INST]} {
    set_max_delay -from [get_pins -quiet ${TEMPLATE_IP_INST}/m_ready] \
                  -to   [get_pins -quiet ${TEMPLATE_IP_INST}/s_ready] \
                  [expr {[get_property $TEMPLATE_IP_CLK period] * 0.5}]
}

#-----------------------------------------------------------------------------
# Standalone analysis, used by scripts/run_sta.py when the block is timed on
# its own. The integrating project overrides all of this.
#-----------------------------------------------------------------------------
if {![info exists TEMPLATE_IP_INST]} {
    set _period [get_property $TEMPLATE_IP_CLK period]
    set _inputs [remove_from_collection [all_inputs] [get_ports -quiet clk]]

    if {[sizeof_collection $_inputs] > 0} {
        set_input_delay -clock $TEMPLATE_IP_CLK [expr {$_period * 0.20}] $_inputs
    }
    if {[sizeof_collection [all_outputs]] > 0} {
        set_output_delay -clock $TEMPLATE_IP_CLK [expr {$_period * 0.20}] [all_outputs]
    }
}
