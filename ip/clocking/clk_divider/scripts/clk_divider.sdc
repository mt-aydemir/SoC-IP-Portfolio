#=============================================================================
# clk_divider.sdc - constraints for the integer clock divider
#
# Only needed if clk_out is used. If the design consumes clk_en instead - the
# recommended output - the block is ordinary single-clock logic and needs no
# constraints at all beyond the source clock definition.
#
# Usage from the integrating project:
#
#   set DIV_INST  u_div
#   set DIV_RATIO 5
#   source ip/clocking/clk_divider/scripts/clk_divider.sdc
#
# DIV_INST is the instance's hierarchical name, not a cell object, and an empty
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

if {![info exists DIV_INST]} {
    puts "clk_divider.sdc: DIV_INST is not set; nothing constrained"
    return
}
set _p [expr {$DIV_INST eq "" ? "" : "$DIV_INST/"}]
if {![info exists DIV_RATIO]} {
    puts "clk_divider.sdc: DIV_RATIO is not set; nothing constrained"
    return
}
set _base [expr {$DIV_INST eq "" ? "clk_divider" : [string map {/ _} $DIV_INST]}]

#-----------------------------------------------------------------------------
# 1. Declare the divided clock.
#
# This is the constraint that is forgotten most often, and forgetting it is
# worse than getting it wrong: an undeclared generated clock leaves the entire
# divided domain unanalysed, so timing closes trivially and the design fails in
# hardware.
#
# The clock is declared on the block's clk_out and derived from its clk. Both
# are ports of the block, so the names hold in every tool; the flip-flop that
# drives clk_out is named differently by each of them.
#-----------------------------------------------------------------------------
set _out [socip_block_pin $DIV_INST clk_out]
set _src [socip_block_pin $DIV_INST clk]

if {[llength $_out] > 0 && [llength $_src] > 0} {
    create_generated_clock -name ${_base}_clk_out -source $_src \
        -divide_by $DIV_RATIO $_out
}

#-----------------------------------------------------------------------------
# 2. The odd-divisor path.
#
# An odd DIVISOR combines a rising-edge phase with a falling-edge phase. The
# path between them is a genuine half-cycle path, launched on the rising edge
# and captured on the following falling edge, and every tool derives that from
# the clock definition alone: the default analysis is the correct one and no
# exception is declared. A multicycle path here would only restate the default
# - or, written wrongly, relax a real half-cycle check.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# 3. Nothing else.
#
# The counter and the enable output are ordinary synchronous logic in the
# source domain and are covered by the source clock's own constraints.
#-----------------------------------------------------------------------------
