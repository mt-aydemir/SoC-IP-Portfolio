#=============================================================================
# sha256.sdc - timing constraints for the SHA-256 core
#
# One clock domain and no exception: every round completes in one cycle.
#
# Usage from the integrating project:
#
#   set SHA256_INST u_sha
#   source ip/crypto/sha256/scripts/sha256.sdc
#
# SHA256_INST is the instance's hierarchical name, not a cell object, and an
# empty string means the block is the top of the design. Only commands
# common to OpenSTA, Synopsys tools and Vivado are used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists SHA256_INST]} {
    puts "sha256.sdc: SHA256_INST is not set; nothing constrained"
    return
}
set _p [expr {$SHA256_INST eq "" ? "" : "$SHA256_INST/"}]

#-----------------------------------------------------------------------------
# The longest register-to-register path is the round itself: the schedule
# word, then the five-operand sum T1, then T1 + T2 into the working variable
# a. Input words feed
# that sum directly in rounds 0..15, so the path from s_data is reported as
# its own group: it is the one an integrator's input delay adds to.
#-----------------------------------------------------------------------------
set _data [get_nets -quiet ${_p}s_data*]
if {[llength $_data] > 0} {
    group_path -name sha256_input_word -through $_data
}
