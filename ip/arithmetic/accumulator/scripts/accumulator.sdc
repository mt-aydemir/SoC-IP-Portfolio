#=============================================================================
# accumulator.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Usage from the integrating project:
#
#   set ACCUMULATOR_INST u_acc
#   source ip/arithmetic/accumulator/scripts/accumulator.sdc
#
# ACCUMULATOR_INST is the instance's hierarchical name, not a cell object; an
# empty string means the block is the top of the design.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

#-----------------------------------------------------------------------------
# One synchronous register in one clock domain: no crossing, no multi-cycle
# path, no combinational feedback, and therefore no timing exception. The
# default single-cycle analysis is the correct one.
#
# The block's critical path is entirely inside the register's data path: a
# full ACC_WIDTH carry chain, then the saturation decision, then the
# clear/load/enable priority multiplexing. All of it scales with ACC_WIDTH,
# so this is the block whose slack moves when the total is widened.
#
# A loop worth naming: acc_out feeds the adder that produces its own next
# value. That is an ordinary register-to-register path, not a combinational
# loop, but it means the accumulator cannot be retimed - there is nowhere to
# move the register to. A wide accumulator that misses timing has to be
# restructured by the integrator (for example into two half-width
# accumulations combined later), not fixed with constraints.
#-----------------------------------------------------------------------------

if {[info exists ACCUMULATOR_INST]} {
    set _c [get_cells -quiet $ACCUMULATOR_INST]
    if {[llength $_c] > 0} {
        group_path -name accumulator_feedback -through $_c
    }
}

#-----------------------------------------------------------------------------
# Standalone analysis. scripts/run_sta.py sets the clock and the I/O
# environment itself, then sources this file with ACCUMULATOR_INST set to "":
# the block as the top of the design, which is how the stage checks that
# every command above runs in OpenSTA.
#-----------------------------------------------------------------------------
