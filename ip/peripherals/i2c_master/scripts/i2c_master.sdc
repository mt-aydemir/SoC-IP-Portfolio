#=============================================================================
# i2c_master.sdc - timing constraints
#
# A portable constraint fragment for the block, written so that it can be
# sourced from an integrating project's own SDC. It defines only what the
# block itself requires; the integrator supplies the real clock definition and
# the I/O environment. Only commands common to OpenSTA, Synopsys tools and
# Vivado are used.
#
# Usage from the integrating project:
#
#   set I2C_MASTER_CLK [get_clocks clk_core]
#   source ip/peripherals/i2c_master/scripts/i2c_master.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists I2C_MASTER_CLK]} {
    puts "i2c_master.sdc: I2C_MASTER_CLK is not set; using the design's first clock"
    set I2C_MASTER_CLK [lindex [all_clocks] 0]
}

#-----------------------------------------------------------------------------
# One clock domain.
#
# The critical paths are the quarter-period counter, DIV_WIDTH bits
# wide, and the phase and line-level decode feeding scl_oe and
# sda_oe. Both outputs are registered, so the open-drain pads see
# no glitches.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Asynchronous inputs. Each goes straight into a cdc_sync_2ff stage, so the
# path into its first flop has no timing relationship to clk and is cut. The
# synchroniser itself is the protection; see ip/cdc/sync_2ff.
#-----------------------------------------------------------------------------
foreach _port {scl_i sda_i} {
    set _p [get_ports -quiet $_port]
    if {[llength $_p] > 0} {
        set_false_path -from $_p
    }
}
