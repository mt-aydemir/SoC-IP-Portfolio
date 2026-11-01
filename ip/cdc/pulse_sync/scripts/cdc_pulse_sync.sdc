#=============================================================================
# cdc_pulse_sync.sdc - constraints for the pulse synchroniser
#
# Two asynchronous crossings, one in each direction. Both must be declared, or
# the tool will attempt to close timing between unrelated clocks and report
# violations that cannot be fixed.
#
# Usage from the integrating project:
#
#   set PULSE_SYNC_INST u_irq_sync
#   set PULSE_SRC_CLK   [get_clocks clk_periph]
#   set PULSE_DST_CLK   [get_clocks clk_cpu]
#   source ip/cdc/pulse_sync/scripts/cdc_pulse_sync.sdc
#
# PULSE_SYNC_INST is the instance's hierarchical name, not a cell object, and an empty
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

if {![info exists PULSE_SYNC_INST]} {
    puts "cdc_pulse_sync.sdc: PULSE_SYNC_INST is not set; nothing constrained"
    return
}
set _p [expr {$PULSE_SYNC_INST eq "" ? "" : "$PULSE_SYNC_INST/"}]

#-----------------------------------------------------------------------------
# 1. Bound the delay into each synchroniser.
#
# Each crossing has no setup relationship to close, but it does need a bound:
# unbounded, the tool may route it arbitrarily badly. A data-path max-delay
# keeps the source-to-first-flop segment inside one destination clock period,
# so the sampled level is never stale by more than the cycle the design
# assumes. Each crossing is named by the input net of its synchroniser.
#
# The clocks are deliberately not declared asynchronous with set_clock_groups.
# Clock groups take precedence over a max-delay in every tool, so they would
# silently remove these bounds - and they would hide any other path between
# the two clocks, which in this block can only be a design error.
#-----------------------------------------------------------------------------
set _to_dst [get_nets -quiet ${_p}u_sync_to_dst/d_async*]
set _to_src [get_nets -quiet ${_p}u_sync_to_src/d_async*]

if {[info exists PULSE_DST_CLK] && [llength $_to_dst] > 0} {
    socip_max_delay_datapath [socip_clock_period $PULSE_DST_CLK] -through $_to_dst
}
if {[info exists PULSE_SRC_CLK] && [llength $_to_src] > 0} {
    socip_max_delay_datapath [socip_clock_period $PULSE_SRC_CLK] -through $_to_src
}

#-----------------------------------------------------------------------------
# 2. Preserve both synchroniser chains.
#
# See ip/cdc/sync_2ff/scripts/cdc_sync_2ff.sdc for the per-tool commands. The
# intermediate stages exist only to spend time and are provably redundant to an
# optimiser that does not know that.
#-----------------------------------------------------------------------------
