#=============================================================================
# clk_gate.sdc - constraints for the glitch-free clock gate
#
# Usage from the integrating project:
#
#   set GATE_INST    u_gate_dsp
#   set GATE_SRC_CLK [get_clocks clk_sys]
#   source ip/clocking/clk_gate/scripts/clk_gate.sdc
#
# GATE_INST is the instance's hierarchical name, not a cell object, and an empty
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
# Reading a clock's period is spelled differently by every tool: OpenSTA takes
# the object first, Vivado the property name first, and the Synopsys tools use
# get_attribute. Defined once per session; every fragment carries the same copy.
#-----------------------------------------------------------------------------
if {[llength [info procs socip_clock_period]] == 0} {
    proc socip_clock_period {clk} {
        foreach cmd {
            {get_property $clk period}
            {get_property PERIOD $clk}
            {get_attribute $clk period}
        } {
            if {![catch $cmd p] && [string is double -strict $p]} {
                return $p
            }
        }
        error "socip_clock_period: cannot read the period of $clk"
    }
}

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

if {![info exists GATE_INST]} {
    puts "clk_gate.sdc: GATE_INST is not set; nothing constrained"
    return
}
set _p [expr {$GATE_INST eq "" ? "" : "$GATE_INST/"}]
set _base [expr {$GATE_INST eq "" ? "clk_gate" : [string map {/ _} $GATE_INST]}]

#-----------------------------------------------------------------------------
# 1. Declare the gated clock.
#
# A gated clock has the same period as its source; only its enable differs.
# Without this declaration everything clocked by gated_clk is unanalysed.
#-----------------------------------------------------------------------------
set _out [socip_block_pin $GATE_INST gated_clk]
set _src [socip_block_pin $GATE_INST clk]

if {[llength $_out] > 0 && [llength $_src] > 0} {
    create_generated_clock -name ${_base}_gated -source $_src -divide_by 1 $_out
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
set _en [get_nets -quiet ${_p}enable]

if {[info exists GATE_SRC_CLK] && [llength $_en] > 0} {
    set_max_delay [expr {[socip_clock_period $GATE_SRC_CLK] * 0.5}] -through $_en
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
set _test [get_nets -quiet ${_p}test_en]
if {[llength $_test] > 0} {
    set_false_path -through $_test
}
