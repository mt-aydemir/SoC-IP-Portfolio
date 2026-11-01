#=============================================================================
# ram_sdp.sdc - constraints for the simple dual-port RAM
#
# Usage from the integrating project:
#
#   set RAM_INST [get_cells u_storage]
#   set RAM_WR_CLK [get_clocks clk_wr]
#   set RAM_RD_CLK [get_clocks clk_rd]
#   source ip/memory/ram_sdp/scripts/ram_sdp.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists RAM_INST]} {
    puts "ram_sdp.sdc: RAM_INST is not set; nothing to constrain"
    return
}

#-----------------------------------------------------------------------------
# 1. Declare the two clocks asynchronous, when they really are.
#
# Skip this when both ports share one clock: declaring a clock asynchronous to
# itself removes real timing checks.
#-----------------------------------------------------------------------------
if {[info exists RAM_WR_CLK] && [info exists RAM_RD_CLK]} {
    if {[get_property $RAM_WR_CLK name] ne [get_property $RAM_RD_CLK name]} {
        set_clock_groups -asynchronous -group $RAM_WR_CLK -group $RAM_RD_CLK
    }
}

#-----------------------------------------------------------------------------
# 2. There is no cross-domain data path to constrain.
#
# This is worth stating because it is the block's whole advantage over a true
# dual-port memory. The write port only writes and the read port only reads, so
# the array has a single driving process and no path crosses from one clock to
# the other inside the block.
#
# The synchronisation the design needs is therefore entirely outside this
# block, in whatever tells the reader that a word is available. fifo_async is
# exactly that logic, which is why it is built on this memory.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# 3. Storage inference - see ip/memory/ram_sp/scripts/ram_sp.sdc.
#-----------------------------------------------------------------------------
