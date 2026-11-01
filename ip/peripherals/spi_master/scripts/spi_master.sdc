#=============================================================================
# spi_master.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Usage from the integrating project:
#
#   set SPI_MASTER_CLK [get_clocks clk_core]
#   source ip/peripherals/spi_master/scripts/spi_master.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists SPI_MASTER_CLK]} {
    puts "spi_master.sdc: SPI_MASTER_CLK is not set; using the design's first clock"
    set SPI_MASTER_CLK [lindex [all_clocks] 0]
}

#-----------------------------------------------------------------------------
# One clock domain.
#
# miso is not synchronised: it is synchronous to the SCLK this
# block generates. It is sampled on the clk edge that produces the
# sampling SCLK edge, so the round trip - clk to the sclk pad,
# board, slave clock-to-out, board, miso pad - must fit in one SCLK
# half period of clk_div cycles. With clk_div >= 2 the integrator
# may declare that as a multicycle path:
#
#   set_multicycle_path -setup $clk_div -from [get_ports miso]
#   set_multicycle_path -hold [expr {$clk_div - 1}] \
#       -from [get_ports miso]
#-----------------------------------------------------------------------------
