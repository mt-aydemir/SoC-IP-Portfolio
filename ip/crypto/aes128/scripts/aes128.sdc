#=============================================================================
# aes128.sdc - timing constraints for the AES-128 core
#
# One clock domain and no exception: every round, and every key-schedule
# step, completes in one cycle. The stored round keys change only on a key
# load, but a block may start on the cycle after the load completes, so they
# are not quasi-static and no multicycle path may be applied to them.
#
# Usage from the integrating project:
#
#   set AES128_INST u_aes
#   source ip/crypto/aes128/scripts/aes128.sdc
#
# AES128_INST is the instance's hierarchical name, not a cell object, and an
# empty string means the block is the top of the design. Only commands
# common to OpenSTA, Synopsys tools and Vivado are used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists AES128_INST]} {
    puts "aes128.sdc: AES128_INST is not set; nothing constrained"
    return
}
set _p [expr {$AES128_INST eq "" ? "" : "$AES128_INST/"}]

#-----------------------------------------------------------------------------
# The longest register-to-register path is a decryption round: the key
# schedule step backward (an S-box behind two XORs) into AddRoundKey, then
# InvMixColumns. The combinational path from key_valid to s_ready - a key
# load takes precedence over a block - is reported as its own group.
#-----------------------------------------------------------------------------
set _key_valid [get_nets -quiet ${_p}key_valid]
if {[llength $_key_valid] > 0} {
    group_path -name aes128_key_valid -through $_key_valid
}
