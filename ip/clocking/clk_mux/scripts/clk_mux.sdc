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
#   set MUX_INST [get_cells u_clk_sel]
#   set MUX_CLK0 [get_clocks clk_ref]
#   set MUX_CLK1 [get_clocks clk_pll]
#   source ip/clocking/clk_mux/scripts/clk_mux.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists MUX_INST]} {
    puts "clk_mux.sdc: MUX_INST is not set; constraining every instance"
    set MUX_INST [get_cells -hierarchical -filter {REF_NAME =~ clk_mux*}]
}

#-----------------------------------------------------------------------------
# 1. The two sources are asynchronous to each other.
#-----------------------------------------------------------------------------
if {[info exists MUX_CLK0] && [info exists MUX_CLK1]} {
    set_clock_groups -asynchronous -group $MUX_CLK0 -group $MUX_CLK1
}

#-----------------------------------------------------------------------------
# 2. Two generated clocks on the same output pin.
#
# -add is required: the second declaration must join the first rather than
# replace it. Downstream logic is then analysed against both possible sources,
# which is correct - it really can be clocked by either.
#-----------------------------------------------------------------------------
set _out_pin [get_pins -quiet ${MUX_INST}/clk_out]

if {[sizeof_collection $_out_pin] > 0} {
    create_generated_clock -name ${MUX_INST}_out_from_clk0 \
        -source [get_pins -quiet ${MUX_INST}/clk0] \
        -divide_by 1 \
        $_out_pin

    create_generated_clock -name ${MUX_INST}_out_from_clk1 \
        -source [get_pins -quiet ${MUX_INST}/clk1] \
        -divide_by 1 -add \
        $_out_pin
}

#-----------------------------------------------------------------------------
# 3. The two generated clocks are mutually exclusive.
#
# Only one can drive the output at a time - that is the whole point of the
# block. Without this, every register downstream is analysed for a path
# launched by the clk0 version and captured by the clk1 version, which is a
# path that physically cannot exist and which will never close.
#
# -logically_exclusive rather than -asynchronous: the exclusivity comes from
# the design's logic, not from the clocks being unrelated.
#-----------------------------------------------------------------------------
if {[sizeof_collection $_out_pin] > 0} {
    set_clock_groups -logically_exclusive \
        -group [get_clocks -quiet ${MUX_INST}_out_from_clk0] \
        -group [get_clocks -quiet ${MUX_INST}_out_from_clk1]
}

#-----------------------------------------------------------------------------
# 4. select is asynchronous to both branches.
#
# Each branch synchronises it locally, so the input is a false path into both
# first-stage flip-flops.
#-----------------------------------------------------------------------------
set _sel0_first [get_cells -quiet ${MUX_INST}/sel0_q_reg*0*]
set _sel1_first [get_cells -quiet ${MUX_INST}/sel1_q_reg*0*]

foreach _first [list $_sel0_first $_sel1_first] {
    if {[sizeof_collection $_first] > 0} {
        set_false_path -to [get_pins -quiet ${_first}/D]
    }
}

#-----------------------------------------------------------------------------
# 5. The cross-coupled enables cross domains.
#
# enable1 feeds branch 0's request logic and vice versa. Each is a single bit
# that is stable for many cycles by construction, so a bounded delay is the
# right constraint rather than a full timing check.
#-----------------------------------------------------------------------------
if {[info exists MUX_CLK0] && [sizeof_collection $_sel0_first] > 0} {
    set_max_delay -datapath_only [get_property $MUX_CLK0 period] \
                  -from [get_cells -quiet ${MUX_INST}/enable1_reg] \
                  -to   [get_pins -quiet ${_sel0_first}/D]
}
if {[info exists MUX_CLK1] && [sizeof_collection $_sel1_first] > 0} {
    set_max_delay -datapath_only [get_property $MUX_CLK1 period] \
                  -from [get_cells -quiet ${MUX_INST}/enable0_reg] \
                  -to   [get_pins -quiet ${_sel1_first}/D]
}

#-----------------------------------------------------------------------------
# 6. Preserve both synchroniser chains.
#
# See ip/cdc/sync_2ff/scripts/cdc_sync_2ff.sdc for the per-tool commands.
#-----------------------------------------------------------------------------
