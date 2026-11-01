#=============================================================================
# cic.sdc - timing constraints for the CIC decimator
#
# One clock domain and no exception. The combs run once per output, but they
# compute in the cycle their sample is accepted, so they are a genuine
# single-cycle path: a multicycle path of rate cycles would be wrong for
# rate = 1 and for any rate change.
#
# Usage from the integrating project:
#
#   set CIC_INST u_cic
#   source ip/dsp/cic/scripts/cic.sdc
#
# CIC_INST is the instance's hierarchical name, not a cell object, and an empty
# string means the block is the top of the design. Only commands common to
# OpenSTA, Synopsys tools and Vivado are used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists CIC_INST]} {
    puts "cic.sdc: CIC_INST is not set; nothing constrained"
    return
}
set _p [expr {$CIC_INST eq "" ? "" : "$CIC_INST/"}]

#-----------------------------------------------------------------------------
# The critical path is the comb chain, STAGES subtractors from the last
# integrator to the output register; it is reported as its own group.
#-----------------------------------------------------------------------------
set _combs [get_nets -quiet ${_p}m_data*]
if {[llength $_combs] > 0} {
    group_path -name cic_comb_chain -through $_combs
}
