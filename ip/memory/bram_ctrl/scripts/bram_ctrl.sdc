#=============================================================================
# bram_ctrl.sdc - constraints for the block RAM controller
#
# Usage from the integrating project:
#
#   set CTRL_INST u_bram_ctrl
#   source ip/memory/bram_ctrl/scripts/bram_ctrl.sdc
#
# CTRL_INST is the instance's hierarchical name, not a cell object, and an empty
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

if {![info exists CTRL_INST]} {
    puts "bram_ctrl.sdc: CTRL_INST is not set; nothing constrained"
    return
}
set _p [expr {$CTRL_INST eq "" ? "" : "$CTRL_INST/"}]

#-----------------------------------------------------------------------------
# The block needs no timing exceptions.
#
# It is entirely synchronous to one clock: the request channel, the memory, the
# in-flight tracking and the response buffer all run on it.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# The flow-control path.
#
# req_ready is combinational from the response-buffer occupancy and the
# in-flight flag. It is the path that lets the block accept a request in the
# same cycle the previous response is taken, and it is short, but it is also
# the path a bus bridge in front of the block will extend.
#
# It is reported as its own path group. A max-delay through the pin would
# constrain the whole register-to-register path, the bridge's logic included,
# which is a requirement on the integrator's design rather than on this
# block. If the group misses timing, add a register slice on the request
# channel rather than relaxing the block.
#-----------------------------------------------------------------------------
set _ready [get_nets -quiet ${_p}req_ready]
if {[llength $_ready] > 0} {
    group_path -name bram_ctrl_req_ready -through $_ready
}

#-----------------------------------------------------------------------------
# Storage inference - see ip/memory/ram_sp/scripts/ram_sp.sdc.
#-----------------------------------------------------------------------------
