#=============================================================================
# reset_controller.sdc - constraints for the staged reset controller
#
# Usage from the integrating project:
#
#   set RSTCTL_INST [get_cells u_rstctl]
#   set RSTCTL_CLK  [get_clocks clk_sys]
#   source ip/clocking/reset_controller/scripts/reset_controller.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists RSTCTL_INST]} {
    puts "reset_controller.sdc: RSTCTL_INST is not set; constraining every instance"
    set RSTCTL_INST [get_cells -hierarchical -filter {REF_NAME =~ reset_controller*}]
}

#-----------------------------------------------------------------------------
# 1. The asynchronous reset input is a false path.
#
# arst_n_in has no timing relationship to clk. The block's whole purpose is to
# turn that into something that does, so the raw input is excluded and
# everything downstream of the synchroniser is fully timed.
#
# This delegates to the reset synchroniser's own constraints, since the
# instance inside this block is an ordinary cdc_reset_sync.
#-----------------------------------------------------------------------------
set RST_SYNC_INST [get_cells -quiet ${RSTCTL_INST}/u_sync]

if {[sizeof_collection $RST_SYNC_INST] > 0} {
    set _here [file dirname [info script]]
    if {[file exists ${_here}/../../../cdc/reset_sync/scripts/cdc_reset_sync.sdc]} {
        source ${_here}/../../../cdc/reset_sync/scripts/cdc_reset_sync.sdc
    }
}

#-----------------------------------------------------------------------------
# 2. The staged reset outputs are ordinary synchronous signals.
#
# They are registered inside the block and released synchronously to clk, so
# their recovery and removal checks at every destination flip-flop are real and
# must be met. Do NOT set a false path on them: that is the mistake that
# reintroduces the asynchronous release this block exists to eliminate.
#
# What they do need is a fanout budget. Each stage drives every flip-flop in
# its part of the design.
#-----------------------------------------------------------------------------
set _stage_pins [get_pins -quiet ${RSTCTL_INST}/rst_n_out*]

if {[sizeof_collection $_stage_pins] > 0} {
    set_max_fanout 10000 $_stage_pins
}

#-----------------------------------------------------------------------------
# 3. sw_reset is synchronous.
#
# It is sampled by clk inside the block, so it is timed normally. If the
# integrating design drives it from another clock domain, that crossing must be
# synchronised outside this block - a cdc_pulse_sync is the right choice for a
# reset request from a different domain.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# 4. The stage comparators are not timing critical.
#
# Each stage output is registered directly from a comparison against the
# counter, so the path is counter -> comparator -> flip-flop, entirely within
# one cycle. No exception is needed; this note exists only to record that the
# wide comparator is deliberate and is not a candidate for a multicycle path.
#-----------------------------------------------------------------------------
