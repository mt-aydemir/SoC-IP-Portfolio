#=============================================================================
# clk_gate.sdc - constraints for the glitch-free clock gate
#
# Usage from the integrating project:
#
#   set GATE_INST    [get_cells u_gate_dsp]
#   set GATE_SRC_CLK [get_clocks clk_sys]
#   source ip/clocking/clk_gate/scripts/clk_gate.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists GATE_INST]} {
    puts "clk_gate.sdc: GATE_INST is not set; constraining every instance"
    set GATE_INST [get_cells -hierarchical -filter {REF_NAME =~ clk_gate*}]
}

#-----------------------------------------------------------------------------
# 1. Declare the gated clock.
#
# A gated clock has the same period as its source; only its enable differs.
# Without this declaration everything clocked by gated_clk is unanalysed.
#-----------------------------------------------------------------------------
set _out_pin [get_pins -quiet ${GATE_INST}/gated_clk]

if {[sizeof_collection $_out_pin] > 0} {
    create_generated_clock -name ${GATE_INST}_gated \
        -source [get_pins -quiet ${GATE_INST}/clk] \
        -divide_by 1 \
        $_out_pin
}

#-----------------------------------------------------------------------------
# 2. The enable path is a half-cycle path.
#
# The latch is transparent while the clock is low, so the enable is launched by
# rising-edge logic and must be stable by the following falling edge - half a
# cycle, not a full one. Tools that model the latch correctly derive this
# themselves; stating it makes the requirement visible in reports and prevents
# a tool that borrows time through the latch from hiding a real violation.
#-----------------------------------------------------------------------------
set _en_pin [get_pins -quiet ${GATE_INST}/enable]

if {[info exists GATE_SRC_CLK] && [sizeof_collection $_en_pin] > 0} {
    set_max_delay [expr {[get_property $GATE_SRC_CLK period] * 0.5}] -to $_en_pin
}

#-----------------------------------------------------------------------------
# 3. Preserve the latch.
#
# An optimiser that converts the latch to a flip-flop, or removes it as
# redundant, silently reintroduces the runt pulse the block exists to prevent -
# and the result still simulates correctly at RTL. The command is per-tool:
#
#   Vivado    set_property DONT_TOUCH true [get_cells ${GATE_INST}/enable_latched_reg]
#   Quartus   set_instance_assignment -name PRESERVE_REGISTER ON -to ...
#   DC/Genus  set_dont_touch [get_cells ${GATE_INST}]
#
# Better still, where the target library provides one, replace this block with
# the library's integrated clock gating cell at synthesis time. Most tools do
# that automatically once gate-level clock gating is enabled, and the RTL here
# is written to be recognised by that inference.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# 4. test_en is a static signal.
#
# It is driven by the scan controller and does not change during functional
# operation, so timing it against the functional clock reports a path that
# never switches.
#-----------------------------------------------------------------------------
set _test_pin [get_pins -quiet ${GATE_INST}/test_en]
if {[sizeof_collection $_test_pin] > 0} {
    set_false_path -to $_test_pin
}
