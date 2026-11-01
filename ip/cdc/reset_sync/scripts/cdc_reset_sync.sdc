#=============================================================================
# cdc_reset_sync.sdc - constraints for the reset synchroniser
#
# Usage from the integrating project:
#
#   set RST_SYNC_INST u_rst_sync_core
#   source ip/cdc/reset_sync/scripts/cdc_reset_sync.sdc
#
# RST_SYNC_INST is the instance's hierarchical name, not a cell object, and an empty
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

if {![info exists RST_SYNC_INST]} {
    puts "cdc_reset_sync.sdc: RST_SYNC_INST is not set; nothing constrained"
    return
}
set _p [expr {$RST_SYNC_INST eq "" ? "" : "$RST_SYNC_INST/"}]

#-----------------------------------------------------------------------------
# 1. The asynchronous reset input is a false path.
#
# arst_n_in has no timing relationship to clk by definition. Leaving it timed
# produces a recovery/removal violation that cannot be closed and that masks
# the real ones elsewhere in the design.
#
# This applies only to the reset *input* of this block. The synchronised
# output, rst_n_out, is an ordinary synchronous signal and must stay fully
# timed everywhere it is used - that is the entire reason the block exists.
# Cutting the paths through the input net rather than to the flip-flops' clear
# pins leaves no library pin name in the file.
#-----------------------------------------------------------------------------
set _arst [get_nets -quiet ${_p}arst_n_in]

if {[llength $_arst] > 0} {
    set_false_path -through $_arst
}

#-----------------------------------------------------------------------------
# 2. Preserve the chain.
#
# Every stage after the first has a constant 1 on its input and identical
# clear behaviour, so an optimiser can prove them redundant. They are not:
# their purpose is to spend clock periods while metastability resolves.
#
# The command differs per tool, so it is left to the integrating project:
#   Vivado    set_property DONT_TOUCH true  [get_cells $RST_SYNC_INST]
#   Quartus   set_instance_assignment -name PRESERVE_REGISTER ON -to ...
#   DC/Genus  set_dont_touch [get_cells $RST_SYNC_INST]
#
# Deliberately not expressed as an RTL attribute: a vendor attribute in the
# source would break the portability the library is built on.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# 3. Reset tree fanout.
#
# rst_n_out fans out to every flip-flop in the domain, and its recovery and
# removal checks are real and must be met. It needs a high fanout budget, not
# an exception. That budget is a per-tool setting rather than SDC - Vivado's
# MAX_FANOUT net property, set_max_fanout on the design in the Synopsys flow -
# so it too is left to the integrating project.
#-----------------------------------------------------------------------------
