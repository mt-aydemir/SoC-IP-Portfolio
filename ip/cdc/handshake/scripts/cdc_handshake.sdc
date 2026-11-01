#=============================================================================
# cdc_handshake.sdc - constraints for the request/acknowledge data crossing
#
# Three things must be declared here. The first two are the usual control
# crossings. The third - the payload path - is the one that is easy to forget,
# because it crosses domains with no synchroniser at all. That is by design:
# the payload register is provably static while the destination reads it, so it
# needs no synchroniser, but it still needs a constraint or the tool will try
# to time it between unrelated clocks.
#
# Usage from the integrating project:
#
#   set HS_INST    u_cfg_cross
#   set HS_SRC_CLK [get_clocks clk_cpu]
#   set HS_DST_CLK [get_clocks clk_dsp]
#   source ip/cdc/handshake/scripts/cdc_handshake.sdc
#
# HS_INST is the instance's hierarchical name, not a cell object, and an empty
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

if {![info exists HS_INST]} {
    puts "cdc_handshake.sdc: HS_INST is not set; nothing constrained"
    return
}
set _p [expr {$HS_INST eq "" ? "" : "$HS_INST/"}]

#-----------------------------------------------------------------------------
# 1. Bound the delay into each control synchroniser.
#
# The clocks are deliberately not declared asynchronous with set_clock_groups:
# clock groups take precedence over a max-delay in every tool, so they would
# silently remove the bounds below, and they would hide any other path between
# the two clocks, which in this block can only be a design error.
#-----------------------------------------------------------------------------
set _req [get_nets -quiet ${_p}u_sync_req/d_async*]
set _ack [get_nets -quiet ${_p}u_sync_ack/d_async*]

if {[info exists HS_DST_CLK] && [llength $_req] > 0} {
    socip_max_delay_datapath [socip_clock_period $HS_DST_CLK] -through $_req
}
if {[info exists HS_SRC_CLK] && [llength $_ack] > 0} {
    socip_max_delay_datapath [socip_clock_period $HS_SRC_CLK] -through $_ack
}

#-----------------------------------------------------------------------------
# 2. The payload path.
#
# payload_q is clocked by src_clk and captured into dst_data by dst_clk with no
# synchroniser between them. The protocol guarantees payload_q has been stable
# for at least STAGES destination cycles before that capture happens, so there
# is no metastability risk and no setup relationship worth analysing.
#
# It still needs a bound. Without one the tool may route the bus arbitrarily
# badly, and a payload bit arriving later than the STAGES-cycle stability
# window would be sampled while still in transit. Bounding the path at one
# destination clock period keeps the whole bus inside the window with margin.
# payload_q feeds nothing but that capture, so its net names the path.
#-----------------------------------------------------------------------------
set _payload [get_nets -quiet ${_p}payload_q*]

if {[llength $_payload] > 0} {
    if {[info exists HS_DST_CLK]} {
        socip_max_delay_datapath [socip_clock_period $HS_DST_CLK] -through $_payload
    } else {
        set_false_path -through $_payload
    }
}

#-----------------------------------------------------------------------------
# 3. Preserve both synchroniser chains.
#
# See ip/cdc/sync_2ff/scripts/cdc_sync_2ff.sdc for the per-tool commands.
#-----------------------------------------------------------------------------
