#=============================================================================
# mac_array.sdc - timing constraints for the dot-product array
#
# One clock domain and no exception. Every pipeline stage is a single-cycle
# path; the one combinational path through the block, m_ready to s_ready, is
# reported as its own group because it fans out to every pipeline register's
# enable.
#
# Usage from the integrating project:
#
#   set MAC_ARRAY_INST u_mac
#   source ip/ml/mac_array/scripts/mac_array.sdc
#
# MAC_ARRAY_INST is the instance's hierarchical name, not a cell object, and
# an empty string means the block is the top of the design. Only commands
# common to OpenSTA, Synopsys tools and Vivado are used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists MAC_ARRAY_INST]} {
    puts "mac_array.sdc: MAC_ARRAY_INST is not set; nothing constrained"
    return
}
set _p [expr {$MAC_ARRAY_INST eq "" ? "" : "$MAC_ARRAY_INST/"}]

#-----------------------------------------------------------------------------
# The longest register-to-register path is either the multiplier stage or
# the accumulator stage (an ACC_WIDTH adder); the tree levels are one adder
# each. The stall enable, driven from m_ready, reaches every register.
#-----------------------------------------------------------------------------
set _ready [get_nets -quiet ${_p}m_ready]
if {[llength $_ready] > 0} {
    group_path -name mac_array_stall -through $_ready
}
