#=============================================================================
# ram_dp.sdc - constraints for the true dual-port RAM
#
# Usage from the integrating project:
#
#   set RAM_INST [get_cells u_shared_mem]
#   set RAM_CLK_A [get_clocks clk_cpu]
#   set RAM_CLK_B [get_clocks clk_dsp]
#   source ip/memory/ram_dp/scripts/ram_dp.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists RAM_INST]} {
    puts "ram_dp.sdc: RAM_INST is not set; nothing to constrain"
    return
}

#-----------------------------------------------------------------------------
# 1. Declare the two clocks asynchronous, when they really are.
#-----------------------------------------------------------------------------
if {[info exists RAM_CLK_A] && [info exists RAM_CLK_B]} {
    if {[get_property $RAM_CLK_A name] ne [get_property $RAM_CLK_B name]} {
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
