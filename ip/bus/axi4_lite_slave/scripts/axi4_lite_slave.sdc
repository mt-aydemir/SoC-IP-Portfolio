#=============================================================================
# axi4_lite_slave.sdc - timing constraints for the AXI4-Lite subordinate
#
# One clock domain and no exception. Every AXI output is a flip-flop or a
# function of flip-flops, so the block adds no combinational path to the
# interconnect in front of it.
#
# Usage from the integrating project:
#
#   set AXI4_LITE_SLAVE_INST u_axi4_lite_slave
#   source ip/bus/axi4_lite_slave/scripts/axi4_lite_slave.sdc
#
# AXI4_LITE_SLAVE_INST is the instance's hierarchical name, not a cell object, and an empty
# string means the block is the top of the design. Source the file once per
# instance. Only commands common to OpenSTA, Synopsys tools and Vivado are
# used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists AXI4_LITE_SLAVE_INST]} {
    puts "axi4_lite_slave.sdc: AXI4_LITE_SLAVE_INST is not set; nothing constrained"
    return
}
set _p [expr {$AXI4_LITE_SLAVE_INST eq "" ? "" : "$AXI4_LITE_SLAVE_INST/"}]

#-----------------------------------------------------------------------------
# The register response.
#
# reg_rdata and reg_error are sampled on the accepting edge, so the path from
# the held address through the register block's read multiplexer and back is
# a single-cycle path that runs mostly outside this block. It is reported as
# its own group so a timing report names it.
#-----------------------------------------------------------------------------
set _response [get_nets -quiet [list ${_p}reg_rdata* ${_p}reg_ready ${_p}reg_error]]
if {[llength $_response] > 0} {
    group_path -name axi4_lite_slave_register_response -through $_response
}
