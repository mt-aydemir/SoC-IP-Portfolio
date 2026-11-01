#=============================================================================
# uart.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Usage from the integrating project:
#
#   set UART_CLK [get_clocks clk_core]
#   source ip/peripherals/uart/scripts/uart.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists UART_CLK]} {
    puts "uart.sdc: UART_CLK is not set; using the design's first clock"
    set UART_CLK [lindex [all_clocks] 0]
}

#-----------------------------------------------------------------------------
# One clock domain.
#
# The critical paths are the bit-period counters, DIV_WIDTH bits
# wide, and the receive state decode. clks_per_bit is quasi-static
# (changed only while idle); the integrator may give it a
# multicycle path.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Asynchronous inputs. Each goes straight into a cdc_sync_2ff stage, so the
# path into its first flop has no timing relationship to clk and is cut. The
# synchroniser itself is the protection; see ip/cdc/sync_2ff.
#-----------------------------------------------------------------------------
foreach _port {rxd} {
    set _p [get_ports -quiet $_port]
    if {[llength $_p] > 0} {
        set_false_path -from $_p
    }
}
