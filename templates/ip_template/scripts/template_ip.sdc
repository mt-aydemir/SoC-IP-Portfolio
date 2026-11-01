#=============================================================================
# template_ip.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the clock definition and the
# I/O environment.
#
# Usage from the integrating project:
#
#   set TEMPLATE_IP_INST u_stage
#   source ip/<category>/template_ip/scripts/template_ip.sdc
#
# TEMPLATE_IP_INST is the instance's hierarchical name, not a cell object, and
# an empty string means the block is the top of the design. Source the file
# once per instance. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used, and constraints attach to nets named after the block's
# ports, which every tool keeps. The flow sources this file in the timing
# stage (add_ip STA_SDC), so every command in it is run by a real tool.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists TEMPLATE_IP_INST]} {
    puts "template_ip.sdc: TEMPLATE_IP_INST is not set; nothing constrained"
    return
}
set _p [expr {$TEMPLATE_IP_INST eq "" ? "" : "$TEMPLATE_IP_INST/"}]

#-----------------------------------------------------------------------------
# The block is a single synchronous stage in one clock domain. It contains no
# clock domain crossing, no multi-cycle path and no combinational feedback, so
# it needs no exceptions: the default single-cycle analysis is correct.
#
# The one thing an integrator must be aware of is the combinational path from
# m_ready to s_ready. It is reported as its own path group, so it shows up
# under a recognisable name rather than as an anonymous critical path.
#-----------------------------------------------------------------------------
set _ready [get_nets -quiet ${_p}m_ready]
if {[llength $_ready] > 0} {
    group_path -name template_ip_ready -through $_ready
}
