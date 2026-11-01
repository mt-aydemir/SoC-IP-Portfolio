#=============================================================================
# multiplier.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Usage from the integrating project:
#
#   set MULTIPLIER_INST u_mul
#   source ip/arithmetic/multiplier/scripts/multiplier.sdc
#
# MULTIPLIER_INST is the instance's hierarchical name, not a cell object; an
# empty string means the block is the top of the design.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

#-----------------------------------------------------------------------------
# The block is a single synchronous pipeline in one clock domain. It contains
# no clock domain crossing, no multi-cycle path and no combinational feedback,
# so it needs no timing exceptions: the default single-cycle analysis is the
# correct one.
#
# What it does need is retiming. Every pipeline register is deliberately at
# the output, because synthesis distributes them through the partial-product
# tree far better than hand placement can. Without a retiming pass the
# registers do nothing for the critical path and the block will miss timing at
# any width worth pipelining.
#
# Retiming is enabled in the synthesis tool, not in SDC, so this file cannot
# do it for the integrator. The path group below at least makes the array
# reportable under a recognisable name.
#-----------------------------------------------------------------------------

if {[info exists MULTIPLIER_INST]} {
    set _c [get_cells -quiet $MULTIPLIER_INST]
    if {[llength $_c] > 0} {
        group_path -name multiplier_array -through $_c
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis. scripts/run_sta.py sets the clock and the I/O
# environment itself, then sources this file with MULTIPLIER_INST set to "":
# the block as the top of the design, which is how the stage checks that
# every command above runs in OpenSTA.
#-----------------------------------------------------------------------------
