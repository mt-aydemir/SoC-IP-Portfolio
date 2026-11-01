#=============================================================================
# axi4_stream_slice.sdc - timing constraints for the AXI4-Stream register slice
#
# A register slice exists to shape timing, and it does so by construction:
# the paths it cuts are cut by registers, not by exceptions. There is
# nothing to declare, and nothing here may be declared - a false path or
# multicycle path across a slice would undo the very thing it is for.
#
# Usage from the integrating project:
#
#   set AXI4_STREAM_SLICE_INST u_axi4_stream_slice
#   source ip/bus/axi4_stream_slice/scripts/axi4_stream_slice.sdc
#
# AXI4_STREAM_SLICE_INST is the instance's hierarchical name, not a cell object, and an empty
# string means the block is the top of the design. Source the file once per
# instance. Only commands common to OpenSTA, Synopsys tools and Vivado are
# used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists AXI4_STREAM_SLICE_INST]} {
    puts "axi4_stream_slice.sdc: AXI4_STREAM_SLICE_INST is not set; nothing constrained"
    return
}
set _p [expr {$AXI4_STREAM_SLICE_INST eq "" ? "" : "$AXI4_STREAM_SLICE_INST/"}]

#-----------------------------------------------------------------------------
# What each MODE leaves combinational, for reading a timing report:
#
#   BYPASS   both directions: TVALID and the payload forward, TREADY back
#   FORWARD  TREADY back, through one gate
#   REVERSE  TVALID and the payload forward, through one multiplexer
#   FULL     nothing
#   LIGHT    nothing
#
# The surviving paths are reported under a group each, so a slice that is in
# the wrong mode for its position shows up by name.
#-----------------------------------------------------------------------------
set _ready [get_nets -quiet ${_p}m_axis_tready]
if {[llength $_ready] > 0} {
    group_path -name axi4_stream_slice_tready -through $_ready
}
set _valid [get_nets -quiet ${_p}s_axis_tvalid]
if {[llength $_valid] > 0} {
    group_path -name axi4_stream_slice_tvalid -through $_valid
}
