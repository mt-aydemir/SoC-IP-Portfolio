#=============================================================================
# cdc_reset_sync.sdc - constraints for the reset synchroniser
#
# Usage from the integrating project:
#
#   set RST_SYNC_INST [get_cells u_rst_sync_core]
#   source ip/cdc/reset_sync/scripts/cdc_reset_sync.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists RST_SYNC_INST]} {
    puts "cdc_reset_sync.sdc: RST_SYNC_INST is not set; constraining every instance"
    set RST_SYNC_INST [get_cells -hierarchical -filter {REF_NAME =~ cdc_reset_sync*}]
}

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
#-----------------------------------------------------------------------------
set _stages [get_cells -quiet ${RST_SYNC_INST}/sync_q_reg*]

if {[sizeof_collection $_stages] > 0} {
    set_false_path -to [get_pins -quiet ${_stages}/CLR]
    set_false_path -to [get_pins -quiet ${_stages}/CD]
    set_false_path -to [get_pins -quiet ${_stages}/RN]
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
# 3. Reset tree balancing.
#
# rst_n_out fans out to every flip-flop in the domain. Its own recovery and
# removal checks are real and must be met, so give the net a high fanout
# budget rather than excluding it from analysis.
#-----------------------------------------------------------------------------
set _out [get_pins -quiet ${RST_SYNC_INST}/rst_n_out]
if {[sizeof_collection $_out] > 0} {
    set_max_fanout 10000 $_out
}
