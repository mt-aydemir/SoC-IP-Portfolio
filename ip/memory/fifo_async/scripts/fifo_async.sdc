#=============================================================================
# fifo_async.sdc - constraints for the asynchronous FIFO
#
# This is the one file in the memory category whose constraints are load
# bearing. Without them the pointer crossings are either left unanalysed by
# accident or, worse, analysed as if the clocks were related.
#
# Usage from the integrating project:
#
#   set FIFO_INST   u_cdc_fifo
#   set FIFO_WR_CLK [get_clocks clk_wr]
#   set FIFO_RD_CLK [get_clocks clk_rd]
#   source ip/memory/fifo_async/scripts/fifo_async.sdc
#
# FIFO_INST is the instance's hierarchical name, not a cell object, and an empty
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

if {![info exists FIFO_INST]} {
    puts "fifo_async.sdc: FIFO_INST is not set; nothing constrained"
    return
}
set _p [expr {$FIFO_INST eq "" ? "" : "$FIFO_INST/"}]

#-----------------------------------------------------------------------------
# 1. The clocks are asynchronous, and are not declared so.
#
# set_clock_groups -asynchronous would remove every cross-domain path in one
# statement - including the bounds below, since clock groups take precedence
# over a max-delay in every tool. The block's crossings are instead bounded
# one by one, and any other path between the two clocks, which in this block
# can only be a design error, is reported rather than hidden.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# 2. Bound the delay on each pointer crossing.
#
# A crossing has no setup relationship to close, but unbounded, the tool may
# route the pointer bus arbitrarily badly. Gray coding guarantees that
# a sample taken mid-transition yields either the old value or the new one -
# but only if the bits arrive within one destination clock period of each
# other. Skew larger than that breaks the guarantee, and the failure is a
# corrupted pointer, which means a FIFO that reports the wrong occupancy.
# Each crossing is named by the input net of its synchroniser.
#-----------------------------------------------------------------------------
set _rd_ptr [get_nets -quiet ${_p}u_sync_rd_ptr/d_async*]
set _wr_ptr [get_nets -quiet ${_p}u_sync_wr_ptr/d_async*]

if {[info exists FIFO_WR_CLK] && [llength $_rd_ptr] > 0} {
    socip_max_delay_datapath [socip_clock_period $FIFO_WR_CLK] -through $_rd_ptr
}
if {[info exists FIFO_RD_CLK] && [llength $_wr_ptr] > 0} {
    socip_max_delay_datapath [socip_clock_period $FIFO_RD_CLK] -through $_wr_ptr
}

#-----------------------------------------------------------------------------
# 3. The memory data path.
#
# Data written in the write domain is read in the read domain with no
# synchroniser, which is safe because the pointer handshake guarantees a word
# is only read after its write has been visible for at least SYNC_STAGES read
# cycles. Bound it anyway, for the same reason as the pointers: without a
# bound the tool may route the data bus far more slowly than that window.
#
# The path starts at the storage array, which only the write clock writes,
# and ends at the read register. Paths through the array nets that end on the
# read clock are therefore exactly the crossing. When the array is inferred as
# a RAM macro there are no such nets, nothing matches, and the macro's own
# timing model covers the path instead.
#
# -from the write clock would say the same thing, but combined with -through
# it crashes OpenSTA 3.1.0, so the start is left implied by the array.
#-----------------------------------------------------------------------------
set _array [get_nets -quiet ${_p}u_storage/mem*]

if {[info exists FIFO_RD_CLK] && [llength $_array] > 0} {
    socip_max_delay_datapath [socip_clock_period $FIFO_RD_CLK] \
        -through $_array -to $FIFO_RD_CLK
}

#-----------------------------------------------------------------------------
# 4. Preserve both synchroniser chains.
#
# See ip/cdc/sync_2ff/scripts/cdc_sync_2ff.sdc for the per-tool commands.
#-----------------------------------------------------------------------------
