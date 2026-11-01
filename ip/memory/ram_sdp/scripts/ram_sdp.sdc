#=============================================================================
# ram_sdp.sdc - constraints for the simple dual-port RAM
#
# Usage from the integrating project:
#
#   set RAM_INST u_storage
#   set RAM_WR_CLK [get_clocks clk_wr]
#   set RAM_RD_CLK [get_clocks clk_rd]
#   source ip/memory/ram_sdp/scripts/ram_sdp.sdc
#
# RAM_INST is the instance's hierarchical name, not a cell object. Only
# commands common to OpenSTA, Synopsys tools and Vivado are used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

#-----------------------------------------------------------------------------
# A clock's name, which the tools read as differently as its period.
#-----------------------------------------------------------------------------
if {[llength [info procs socip_clock_name]] == 0} {
    proc socip_clock_name {clk} {
        foreach cmd {
            {get_property $clk name}
            {get_property NAME $clk}
            {get_object_name $clk}
        } {
            if {![catch $cmd n] && $n ne ""} {
                return $n
            }
        }
        error "socip_clock_name: cannot read the name of $clk"
    }
}

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
    if {[socip_clock_name $RAM_WR_CLK] ne [socip_clock_name $RAM_RD_CLK]} {
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
