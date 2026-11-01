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
#   set SYNC_INST u_sync_busy
#   set SYNC_DST  [get_clocks clk_cpu]
#   source ip/cdc/sync_2ff/scripts/cdc_sync_2ff.sdc
#
# SYNC_INST is the instance's hierarchical name, not a cell object, and an empty
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

#-----------------------------------------------------------------------------
# Reading a clock's period is spelled differently by every tool: OpenSTA takes
# the object first, Vivado the property name first, and the Synopsys tools use
# get_attribute. Defined once per session; every fragment carries the same copy.
#-----------------------------------------------------------------------------
if {[llength [info procs socip_clock_period]] == 0} {
    proc socip_clock_period {clk} {
        foreach cmd {
            {get_property $clk period}
            {get_property PERIOD $clk}
            {get_attribute $clk period}
        } {
            if {![catch $cmd p] && [string is double -strict $p]} {
                return $p
            }
        }
        error "socip_clock_period: cannot read the period of $clk"
    }
}

#-----------------------------------------------------------------------------
# A delay bound on the data path alone, clock skew excluded, is -datapath_only
# in Vivado and -ignore_clock_latency in OpenSTA and the Synopsys tools.
#-----------------------------------------------------------------------------
if {[llength [info procs socip_max_delay_datapath]] == 0} {
    proc socip_max_delay_datapath {delay args} {
        if {[catch {set_max_delay -datapath_only $delay {*}$args}]} {
            set_max_delay -ignore_clock_latency $delay {*}$args
        }
    }
}

if {![info exists SYNC_INST]} {
    puts "cdc_sync_2ff.sdc: SYNC_INST is not set; nothing constrained"
    return
}
set _p [expr {$SYNC_INST eq "" ? "" : "$SYNC_INST/"}]

#-----------------------------------------------------------------------------
# 1. The crossing: d_async into the first stage.
#
# The source and destination clocks are asynchronous, so there is no meaningful
# setup or hold relationship to close. What the crossing does need is a bound:
# with WIDTH > 1, lanes allowed unbounded skew can land more than one
# destination period apart and be sampled as two different words. The bound
# keeps the whole bus arriving inside one period.
#
# The bound replaces the setup check rather than accompanying a false path: a
# false path takes precedence over a max-delay in every tool, so declaring both
# leaves the crossing unbounded. Without SYNC_DST the period is unknown, and
# the crossing is cut instead.
#
# d_async drives nothing but the first stage, so the net names the crossing
# exactly, whatever the tool called the flip-flops.
#-----------------------------------------------------------------------------
set _cross [get_nets -quiet ${_p}d_async*]

if {[llength $_cross] > 0} {
    if {[info exists SYNC_DST]} {
        socip_max_delay_datapath [socip_clock_period $SYNC_DST] -through $_cross
    } else {
        set_false_path -through $_cross
    }
}

#-----------------------------------------------------------------------------
# 2. Preserve the chain.
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
