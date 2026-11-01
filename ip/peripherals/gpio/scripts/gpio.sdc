#=============================================================================
# gpio.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Usage from the integrating project:
#
#   set GPIO_CLK [get_clocks clk_core]
#   source ip/peripherals/gpio/scripts/gpio.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists GPIO_CLK]} {
    puts "gpio.sdc: GPIO_CLK is not set; using the design's first clock"
    set GPIO_CLK [lindex [all_clocks] 0]
}

#-----------------------------------------------------------------------------
# One clock domain.
#
# The block's own paths are shallow: the address decode into the
# register enables and the combinational read mux from addr to
# rd_data, which an integrating bus slave usually registers.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Asynchronous inputs. Each goes straight into a cdc_sync_2ff stage, so the
# path into its first flop has no timing relationship to clk and is cut. The
# synchroniser itself is the protection; see ip/cdc/sync_2ff.
#-----------------------------------------------------------------------------
foreach _port {pin_in} {
    set _p [get_ports -quiet $_port]
    if {[llength $_p] > 0} {
        set_false_path -from $_p
    }
}
