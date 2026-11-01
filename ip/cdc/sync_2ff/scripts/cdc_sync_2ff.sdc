#=============================================================================
# cdc_sync_2ff.sdc - constraints for the multi-flop synchroniser
#
# A synchroniser is the one structure in a design whose correctness depends on
# constraints as much as on RTL. Without these, a retiming, register-merging
# or register-duplication optimisation is free to dismantle the chain, and the
# design fails in hardware while passing every simulation.
#
# Usage from the integrating project:
#
#   set SYNC_INST [get_cells u_sync_busy]
#   set SYNC_DST  [get_clocks clk_cpu]
#   source ip/cdc/sync_2ff/scripts/cdc_sync_2ff.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists SYNC_INST]} {
    puts "cdc_sync_2ff.sdc: SYNC_INST is not set; constraining every instance"
    set SYNC_INST [get_cells -hierarchical -filter {REF_NAME =~ cdc_sync_2ff*}]
}

#-----------------------------------------------------------------------------
# 1. The crossing itself is a false path for setup and hold.
#
# The source and destination clocks are asynchronous, so there is no meaningful
# setup or hold relationship to close. Reporting the path would produce a
# violation that cannot be fixed and that hides real ones.
#-----------------------------------------------------------------------------
set _first_stage [get_cells -quiet ${SYNC_INST}/sync_q_reg*0*]

if {[sizeof_collection $_first_stage] > 0} {
    set_false_path -to [get_pins -quiet ${_first_stage}/D]
}

#-----------------------------------------------------------------------------
# 2. Bound the skew into the first stage.
#
# A false path removes the timing check entirely, which is correct for a single
# bit but dangerous for WIDTH > 1: if the lanes are allowed unbounded skew, two
# bits of the same word can land more than one destination clock period apart.
# The max-delay constraint keeps the whole bus arriving inside one period.
#
# -datapath_only tells the tool to ignore clock skew and jitter in the check,
# which is what makes this a pure interconnect-delay bound.
#-----------------------------------------------------------------------------
if {[info exists SYNC_DST] && [sizeof_collection $_first_stage] > 0} {
    set _period [get_property $SYNC_DST period]
    set_max_delay -datapath_only $_period -to [get_pins -quiet ${_first_stage}/D]
}

#-----------------------------------------------------------------------------
# 3. Preserve the chain.
#
# The intermediate flip-flops have identical logic behind them, so an optimiser
# can legitimately conclude they are redundant. They are not: their only
# purpose is to spend time. Marking the cells as do-not-touch is expressed
# differently by every tool, so it is left to the integrating project's own
# script; the RTL deliberately carries no vendor attribute for it.
#
# The equivalent commands are, for reference:
#   Vivado    set_property DONT_TOUCH true      [get_cells $SYNC_INST]
#   Quartus   set_instance_assignment -name PRESERVE_REGISTER ON -to ...
#   Design Compiler / Genus    set_dont_touch [get_cells $SYNC_INST]
#-----------------------------------------------------------------------------
