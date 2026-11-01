#=============================================================================
# ram_sp.sdc - constraints for the single-port RAM
#
# Usage from the integrating project:
#
#   set RAM_INST [get_cells u_mem]
#   source ip/memory/ram_sp/scripts/ram_sp.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists RAM_INST]} {
    puts "ram_sp.sdc: RAM_INST is not set; nothing to constrain"
    return
}

#-----------------------------------------------------------------------------
# The block needs no timing exceptions.
#
# Everything in it is synchronous to one clock: the array is written and read
# on the same edge, and the optional output register adds a second ordinary
# pipeline stage. The default single-cycle analysis is correct throughout.
#
# This file therefore exists for the implementation guidance below rather than
# for constraints, and applying it is optional.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Storage inference.
#
# The RTL carries no ram_style attribute, deliberately: a vendor attribute in
# the source would break the portability the library is built on. Guide the
# choice from here instead, where it belongs to the project rather than to the
# IP. The command differs per tool:
#
#   Vivado    set_property RAM_STYLE block [get_cells ${RAM_INST}/mem_reg*]
#   Quartus   set_instance_assignment -name RAMSTYLE M20K -to ...
#   DC/Genus  handled by the memory compiler flow, not by SDC
#
# Left unguided, every synthesiser makes a reasonable choice from the array
# dimensions: small arrays become distributed RAM or flip-flops, larger ones
# become block RAM.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Output register placement.
#
# With OUTPUT_REG enabled, the register should be absorbed into the memory
# macro rather than implemented in fabric. On an FPGA that makes it free in
# area and a large win in Fmax. Most tools do this automatically when the
# register is enabled by the same signal as the memory, which is why the RTL
# gates it with en rather than with a separate enable.
#-----------------------------------------------------------------------------
