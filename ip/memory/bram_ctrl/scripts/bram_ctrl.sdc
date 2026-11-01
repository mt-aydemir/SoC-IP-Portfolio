#=============================================================================
# bram_ctrl.sdc - constraints for the block RAM controller
#
# Usage from the integrating project:
#
#   set CTRL_INST [get_cells u_bram_ctrl]
#   set CTRL_CLK  [get_clocks clk_bus]
#   source ip/memory/bram_ctrl/scripts/bram_ctrl.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists CTRL_INST]} {
    puts "bram_ctrl.sdc: CTRL_INST is not set; nothing to constrain"
    return
}

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
# Bounding it at half a period keeps enough margin for that bridge; if the
# constraint cannot be met, add a register slice on the request channel rather
# than relaxing the block.
#-----------------------------------------------------------------------------
if {[info exists CTRL_CLK]} {
    set _period [get_property $CTRL_CLK period]
    set _ready [get_pins -quiet ${CTRL_INST}/req_ready]
    if {[sizeof_collection $_ready] > 0} {
        set_max_delay [expr {$_period * 0.5}] -to $_ready
    }
}

#-----------------------------------------------------------------------------
# Storage inference - see ip/memory/ram_sp/scripts/ram_sp.sdc.
#-----------------------------------------------------------------------------
