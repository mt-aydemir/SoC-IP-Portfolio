#=============================================================================
# mac.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Usage from the integrating project:
#
#   set MAC_INST u_mac
#   source ip/arithmetic/mac/scripts/mac.sdc
#
# MAC_INST is the instance's hierarchical name, not a cell object; an
# empty string means the block is the top of the design.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

#-----------------------------------------------------------------------------
# One synchronous pipeline in one clock domain: no crossing, no multi-cycle
# path, no combinational feedback, and therefore no timing exception. The
# default single-cycle analysis is the correct one.
#
# The block has two distinct critical paths, and they respond to completely
# different fixes:
#
#   multiplier array   Can be improved by retiming, which needs the
#                      multiplier's LATENCY raised so there are registers to
#                      retime. Enabled in the synthesis tool, not here.
#
#   accumulator loop   Cannot be retimed at all: the accumulator's register
#                      feeds the adder that computes its own next value, so
#                      there is nowhere to move a register to. A wide
#                      accumulator that misses timing has to be restructured
#                      by the integrator - for example into two half-width
#                      accumulations combined after the frame - not fixed with
#                      constraints or extra pipeline stages.
#
# Reporting them separately is therefore worth the two path groups: knowing
# which of the two is critical tells the integrator which fix to reach for.
#-----------------------------------------------------------------------------

if {[info exists MAC_INST]} {
    set _prefix [expr {$MAC_INST eq "" ? "" : "$MAC_INST/"}]
    foreach {_group _cell} {mac_multiplier u_multiplier mac_accumulator u_accumulator} {
        set _c [get_cells -quiet ${_prefix}${_cell}]
        if {[llength $_c] > 0} {
            group_path -name $_group -through $_c
        }
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis. scripts/run_sta.py sets the clock and the I/O
# environment itself, then sources this file with MAC_INST set to "":
# the block as the top of the design, which is how the stage checks that
# every command above runs in OpenSTA.
#-----------------------------------------------------------------------------
