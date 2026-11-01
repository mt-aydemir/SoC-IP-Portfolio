#=============================================================================
# ram_dp.sdc - constraints for the true dual-port RAM
#
# Usage from the integrating project:
#
#   set RAM_INST u_shared_mem
#   set RAM_CLK_A [get_clocks clk_cpu]
#   set RAM_CLK_B [get_clocks clk_dsp]
#   source ip/memory/ram_dp/scripts/ram_dp.sdc
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
    puts "ram_dp.sdc: RAM_INST is not set; nothing to constrain"
    return
}

#-----------------------------------------------------------------------------
# 1. Declare the two clocks asynchronous, when they really are.
#-----------------------------------------------------------------------------
if {[info exists RAM_CLK_A] && [info exists RAM_CLK_B]} {
    if {[socip_clock_name $RAM_CLK_A] ne [socip_clock_name $RAM_CLK_B]} {
        set_clock_groups -asynchronous -group $RAM_CLK_A -group $RAM_CLK_B
    }
}

#-----------------------------------------------------------------------------
# 2. What the constraints cannot do for you.
#
# The array is written from both ports. No timing constraint makes a
# same-address collision safe, because the hazard is inside the memory macro
# and is a physical property of it, not a path a tool can analyse.
#
# The design must guarantee the ports never touch the same address in the same
# cycle. The usual approaches are:
#
#   * partition the address space, so each port owns a disjoint region;
#   * arbitrate outside the block, so only one port is enabled at a time;
#   * use fifo_async, which is this memory plus the pointer logic that makes
#     the sharing provably safe.
#
# If none of those apply, the design is relying on undefined behaviour.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# 3. Storage inference - see ip/memory/ram_sp/scripts/ram_sp.sdc.
#
# Note that a true dual-port macro is substantially larger than a 1R1W one on
# most targets. If the design only needs one writer, ram_sdp is cheaper.
#-----------------------------------------------------------------------------
