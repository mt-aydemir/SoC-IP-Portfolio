#=============================================================================
# register_file.sdc - constraints for the multi-port register file
#
# Usage from the integrating project:
#
#   set RF_INST u_regfile
#   source ip/memory/register_file/scripts/register_file.sdc
#
# RF_INST is the instance's hierarchical name, not a cell object, and an empty
# string means the block is the top of the design. Source the file once per
# instance. Constraints attach to nets named after the block's ports, which
# every tool keeps, rather than to register names, which every tool changes.
#
# Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists RF_INST]} {
    puts "register_file.sdc: RF_INST is not set; nothing constrained"
    return
}
set _p [expr {$RF_INST eq "" ? "" : "$RF_INST/"}]

#-----------------------------------------------------------------------------
# The read ports are combinational.
#
# Every read address feeds a multiplexer over the whole array, and the result
# is expected in the same cycle. That path is the block's critical path by
# construction and it is a normal single-cycle path - no exception applies.
#
# The path group makes it visible under a recognisable name, so that a timing
# report shows "register file read" rather than an anonymous critical path
# through a large multiplexer.
#-----------------------------------------------------------------------------
set _read [get_nets -quiet ${_p}read_data*]
if {[llength $_read] > 0} {
    group_path -name register_file_read -through $_read
}

#-----------------------------------------------------------------------------
# The write-to-read bypass.
#
# With BYPASS_WRITE enabled the write data reaches the read output through a
# comparator and a multiplexer, entirely combinationally. It is part of the
# same single-cycle path above and needs no separate exception; it is called
# out here only because it is the segment that usually dominates.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Storage inference.
#
# A register file is flip-flops plus multiplexers by definition, because the
# reads are asynchronous. Do not attempt to force it into a block RAM: a block
# RAM cannot provide a combinational read, and a tool that tries will either
# refuse or insert a cycle of latency the surrounding logic does not expect.
#
# If the target really needs the density of a memory macro, the correct change
# is architectural - move to ram_sdp and add a pipeline stage - not a
# constraint.
#-----------------------------------------------------------------------------
