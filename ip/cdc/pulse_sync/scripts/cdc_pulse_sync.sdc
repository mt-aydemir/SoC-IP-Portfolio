#=============================================================================
# cdc_pulse_sync.sdc - constraints for the pulse synchroniser
#
# Two asynchronous crossings, one in each direction. Both must be declared, or
# the tool will attempt to close timing between unrelated clocks and report
# violations that cannot be fixed.
#
# Usage from the integrating project:
#
#   set PULSE_SYNC_INST [get_cells u_irq_sync]
#   set PULSE_SRC_CLK   [get_clocks clk_periph]
#   set PULSE_DST_CLK   [get_clocks clk_cpu]
#   source ip/cdc/pulse_sync/scripts/cdc_pulse_sync.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists PULSE_SYNC_INST]} {
    puts "cdc_pulse_sync.sdc: PULSE_SYNC_INST is not set; constraining every instance"
    set PULSE_SYNC_INST [get_cells -hierarchical -filter {REF_NAME =~ cdc_pulse_sync*}]
}

#-----------------------------------------------------------------------------
# 1. Declare the two clocks asynchronous to each other.
#
# This is the single most important line in the file. It removes every
# cross-domain path in one statement, including paths the instance-level
# constraints below would miss.
#-----------------------------------------------------------------------------
if {[info exists PULSE_SRC_CLK] && [info exists PULSE_DST_CLK]} {
    set_clock_groups -asynchronous \
        -group $PULSE_SRC_CLK \
        -group $PULSE_DST_CLK
}

#-----------------------------------------------------------------------------
# 2. Bound the delay into each synchroniser.
#
# set_clock_groups removes the timing check entirely, which is correct, but it
# also lets the tool route the crossing arbitrarily badly. A max-delay bound
# keeps the source-to-first-flop segment inside one destination clock period,
# so the sampled level is never stale by more than the cycle the design
# assumes.
#
# -datapath_only excludes clock skew and jitter, making this a pure
# interconnect-delay bound rather than a setup check in disguise.
#-----------------------------------------------------------------------------
set _to_dst [get_cells -quiet ${PULSE_SYNC_INST}/u_sync_to_dst/sync_q_reg*0*]
set _to_src [get_cells -quiet ${PULSE_SYNC_INST}/u_sync_to_src/sync_q_reg*0*]

if {[info exists PULSE_DST_CLK] && [sizeof_collection $_to_dst] > 0} {
    set_max_delay -datapath_only [get_property $PULSE_DST_CLK period] \
                  -to [get_pins -quiet ${_to_dst}/D]
}

if {[info exists PULSE_SRC_CLK] && [sizeof_collection $_to_src] > 0} {
    set_max_delay -datapath_only [get_property $PULSE_SRC_CLK period] \
                  -to [get_pins -quiet ${_to_src}/D]
}

#-----------------------------------------------------------------------------
# 3. Preserve both synchroniser chains.
#
# See ip/cdc/sync_2ff/scripts/cdc_sync_2ff.sdc for the per-tool commands. The
# intermediate stages exist only to spend time and are provably redundant to an
# optimiser that does not know that.
#-----------------------------------------------------------------------------
