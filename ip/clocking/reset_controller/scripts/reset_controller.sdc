#=============================================================================
# reset_controller.sdc - constraints for the staged reset controller
#
# Usage from the integrating project:
#
#   set RSTCTL_INST u_rstctl
#   source ip/clocking/reset_controller/scripts/reset_controller.sdc
#
# RSTCTL_INST is the instance's hierarchical name, not a cell object, and an empty
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

if {![info exists RSTCTL_INST]} {
    puts "reset_controller.sdc: RSTCTL_INST is not set; nothing constrained"
    return
}
set _p [expr {$RSTCTL_INST eq "" ? "" : "$RSTCTL_INST/"}]

#-----------------------------------------------------------------------------
# 1. The asynchronous reset input is a false path.
#
# arst_n_in has no timing relationship to clk. The block's whole purpose is to
# turn that into something that does, so the raw input is excluded and
# everything downstream of the synchroniser is fully timed.
#
# This delegates to the reset synchroniser's own constraints, since the
# instance inside this block is an ordinary cdc_reset_sync. The fragment is
# looked up beside this one in the repository layout; an integrator who has
# copied only this IP sources it themselves with RST_SYNC_INST set as below.
#-----------------------------------------------------------------------------
set RST_SYNC_INST ${_p}u_sync
set _reset_sync_sdc [file join [file dirname [info script]] \
    .. .. .. cdc reset_sync scripts cdc_reset_sync.sdc]

if {[file exists $_reset_sync_sdc]} {
    source $_reset_sync_sdc
} else {
    puts "reset_controller.sdc: $_reset_sync_sdc not found; source it for $RST_SYNC_INST"
}

#-----------------------------------------------------------------------------
# 2. The staged reset outputs are ordinary synchronous signals.
#
# They are registered inside the block and released synchronously to clk, so
# their recovery and removal checks at every destination flip-flop are real and
# must be met. Do NOT set a false path on them: that is the mistake that
# reintroduces the asynchronous release this block exists to eliminate.
#
# What they do need is a fanout budget, since each stage drives every
# flip-flop in its part of the design. As for cdc_reset_sync, that is a
# per-tool setting rather than SDC and is left to the integrating project.
#-----------------------------------------------------------------------------

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
