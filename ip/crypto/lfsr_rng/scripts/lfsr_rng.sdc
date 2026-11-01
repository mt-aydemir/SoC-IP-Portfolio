#=============================================================================
# lfsr_rng.sdc - timing constraints for the LFSR generator
#
# One clock domain and no exception. The seed port is a real single-cycle
# path - a seed load generates the first draw on the same edge - so it may
# not be declared false or multicycle.
#
# Usage from the integrating project:
#
#   set LFSR_RNG_INST u_rng
#   source ip/crypto/lfsr_rng/scripts/lfsr_rng.sdc
#
# LFSR_RNG_INST is the instance's hierarchical name, not a cell object, and
# an empty string means the block is the top of the design. Only commands
# common to OpenSTA, Synopsys tools and Vivado are used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists LFSR_RNG_INST]} {
    puts "lfsr_rng.sdc: LFSR_RNG_INST is not set; nothing constrained"
    return
}
set _p [expr {$LFSR_RNG_INST eq "" ? "" : "$LFSR_RNG_INST/"}]

#-----------------------------------------------------------------------------
# The critical path is the draw network: STEPS levels of the feedback XOR,
# behind the seed multiplexer. It grows with STEPS, so the seed-load path is
# reported as its own group.
#-----------------------------------------------------------------------------
set _load [get_nets -quiet ${_p}seed_load]
if {[llength $_load] > 0} {
    group_path -name lfsr_rng_seed_load -through $_load
}
