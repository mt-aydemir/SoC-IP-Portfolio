#=============================================================================
# clk_mux.sdc - constraints for the glitch-free clock multiplexer
#
# The output is a generated clock derived from *two* sources, which is what
# makes this block's constraints unusual: both derivations must be declared,
# and then the two must be declared mutually exclusive so the tool does not
# try to time a path that is launched by one and captured by the other.
#
# Usage from the integrating project:
#
#   set MUX_INST u_clk_sel
#   set MUX_CLK0 [get_clocks clk_ref]
#   set MUX_CLK1 [get_clocks clk_pll]
#   source ip/clocking/clk_mux/scripts/clk_mux.sdc
#
# MUX_INST is the instance's hierarchical name, not a cell object, and an empty
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

#-----------------------------------------------------------------------------
# One of the block's own pins: a port when the block is the top of the design,
# a hierarchical pin otherwise.
#-----------------------------------------------------------------------------
if {[llength [info procs socip_block_pin]] == 0} {
    proc socip_block_pin {inst name} {
        if {$inst eq ""} {
            return [get_ports -quiet $name]
        }
        return [get_pins -quiet $inst/$name]
    }
}

if {![info exists MUX_INST]} {
    puts "clk_mux.sdc: MUX_INST is not set; nothing constrained"
    return
}
set _p [expr {$MUX_INST eq "" ? "" : "$MUX_INST/"}]
set _base [expr {$MUX_INST eq "" ? "clk_mux" : [string map {/ _} $MUX_INST]}]

#-----------------------------------------------------------------------------
# 1. The two sources are asynchronous to each other.
#
# They are deliberately not declared so with set_clock_groups. The block's
# crossings between them are bounded below, and clock groups take precedence
# over a max-delay in every tool, so they would silently remove those bounds.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# 2. Two generated clocks on the same output pin.
#
# -add is required: the second declaration must join the first rather than
# replace it. Downstream logic is then analysed against both possible sources,
# which is correct - it really can be clocked by either.
#
# -add in turn requires -master_clock on both declarations, naming which of
# the clocks reaching the source pin each one follows; every tool rejects -add
# without it. That needs both source clocks, so nothing is declared until the
# integrator has named them.
#-----------------------------------------------------------------------------
set _out  [socip_block_pin $MUX_INST clk_out]
set _src0 [socip_block_pin $MUX_INST clk0]
set _src1 [socip_block_pin $MUX_INST clk1]

if {[info exists MUX_CLK0] && [info exists MUX_CLK1] &&
    [llength $_out] > 0 && [llength $_src0] > 0 && [llength $_src1] > 0} {
    create_generated_clock -name ${_base}_out_from_clk0 -source $_src0 \
        -master_clock $MUX_CLK0 -divide_by 1 $_out
    create_generated_clock -name ${_base}_out_from_clk1 -source $_src1 \
        -master_clock $MUX_CLK1 -divide_by 1 -add $_out

    #-------------------------------------------------------------------------
    # 3. The two generated clocks are mutually exclusive.
    #
    # Only one can drive the output at a time - that is the whole point of the
    # block. Without this, every register downstream is analysed for a path
    # launched by the clk0 version and captured by the clk1 version, which is
    # a path that physically cannot exist and which will never close.
    #
    # -logically_exclusive rather than -asynchronous: the exclusivity comes
    # from the design's logic, not from the clocks being unrelated.
    #-------------------------------------------------------------------------
    set_clock_groups -logically_exclusive \
        -group [get_clocks ${_base}_out_from_clk0] \
        -group [get_clocks ${_base}_out_from_clk1]
}

#-----------------------------------------------------------------------------
# 4. select is asynchronous to both branches.
#
# Each branch synchronises it locally, so every path through the select input
# is a crossing into one of the two first-stage flip-flops, and is cut.
#-----------------------------------------------------------------------------
set _select [get_nets -quiet ${_p}select]
if {[llength $_select] > 0} {
    set_false_path -through $_select
}

#-----------------------------------------------------------------------------
# 5. The cross-coupled state crosses domains.
#
# Branch 0's request is qualified with branch 1's enable and synchroniser
# state, and vice versa. Each of those bits is stable for many cycles by
# construction, so a bounded delay is the right constraint rather than a full
# timing check. They reach the other branch's first stage through logic a
# synthesiser freely restructures - an inverted flip-flop output, a merged
# OR - so no net name holds them in every netlist.
#
# The bound is therefore stated between the clocks: every path from one
# source clock to the other, at one period of the capturing clock. That
# reaches beyond this instance, to any other path between the same two
# clocks, but it is still narrower than the asynchronous clock group this file
# used to declare, which cut all of them. -from a clock is not combined with
# -through, which crashes OpenSTA 3.1.0.
#-----------------------------------------------------------------------------
if {[info exists MUX_CLK0] && [info exists MUX_CLK1]} {
    socip_max_delay_datapath [socip_clock_period $MUX_CLK0] \
        -from $MUX_CLK1 -to $MUX_CLK0
    socip_max_delay_datapath [socip_clock_period $MUX_CLK1] \
        -from $MUX_CLK0 -to $MUX_CLK1
}

#-----------------------------------------------------------------------------
# 6. Preserve both synchroniser chains.
#
# See ip/cdc/sync_2ff/scripts/cdc_sync_2ff.sdc for the per-tool commands.
#-----------------------------------------------------------------------------
