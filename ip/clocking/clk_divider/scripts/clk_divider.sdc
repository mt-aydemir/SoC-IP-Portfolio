#=============================================================================
# clk_divider.sdc - constraints for the integer clock divider
#
# Only needed if clk_out is used. If the design consumes clk_en instead - the
# recommended output - the block is ordinary single-clock logic and needs no
# constraints at all beyond the source clock definition.
#
# Usage from the integrating project:
#
#   set DIV_INST    [get_cells u_div]
#   set DIV_SRC_CLK [get_clocks clk_sys]
#   set DIV_RATIO   5
#   source ip/clocking/clk_divider/scripts/clk_divider.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists DIV_INST]} {
    puts "clk_divider.sdc: DIV_INST is not set; nothing to constrain"
    return
}
if {![info exists DIV_SRC_CLK] || ![info exists DIV_RATIO]} {
    puts "clk_divider.sdc: DIV_SRC_CLK and DIV_RATIO must both be set"
    return
}

#-----------------------------------------------------------------------------
# 1. Declare the divided clock.
#
# This is the constraint that is forgotten most often, and forgetting it is
# worse than getting it wrong: an undeclared generated clock leaves the entire
# divided domain unanalysed, so timing closes trivially and the design fails in
# hardware.
#
# The source is the flip-flop that produces the output, not the module port,
# so that the tool includes the clock tree insertion delay up to that point.
#-----------------------------------------------------------------------------
set _out_pin [get_pins -quiet ${DIV_INST}/clk_out]

if {[sizeof_collection $_out_pin] > 0} {
    create_generated_clock -name ${DIV_INST}_clk_out \
        -source [get_pins -quiet ${DIV_INST}/clk] \
        -divide_by $DIV_RATIO \
        $_out_pin
}

#-----------------------------------------------------------------------------
# 2. The odd-divisor path.
#
# An odd DIVISOR combines a rising-edge phase with a falling-edge phase. The
# path between them is a genuine half-cycle path: launched on the rising edge,
# captured on the following falling edge. Most tools analyse this correctly
# from the clock definition alone, but stating it makes the intent explicit and
# stops an aggressive tool from treating it as a full cycle.
#-----------------------------------------------------------------------------
set _rise_ff [get_cells -quiet ${DIV_INST}/g_divide.g_odd.phase_rise_q_reg]
set _fall_ff [get_cells -quiet ${DIV_INST}/g_divide.g_odd.phase_fall_q_reg]

if {[sizeof_collection $_rise_ff] > 0 && [sizeof_collection $_fall_ff] > 0} {
    set_multicycle_path -setup 1 -from $_rise_ff -to $_fall_ff
    set_multicycle_path -hold  0 -from $_rise_ff -to $_fall_ff
}

#-----------------------------------------------------------------------------
# 3. Nothing else.
#
# The counter and the enable output are ordinary synchronous logic in the
# source domain and are covered by the source clock's own constraints.
#-----------------------------------------------------------------------------
