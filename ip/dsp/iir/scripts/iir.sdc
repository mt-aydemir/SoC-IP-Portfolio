#=============================================================================
# iir.sdc - timing constraints for the biquad
#
# One clock domain and no exception. The feedback loop from y[n-1] back to
# y[n] cannot be pipelined without changing the filter, so it sets the
# sample rate, and no constraint can relax it.
#
# Usage from the integrating project:
#
#   set IIR_INST u_iir
#   source ip/dsp/iir/scripts/iir.sdc
#
# IIR_INST is the instance's hierarchical name, not a cell object, and an empty
# string means the block is the top of the design. Only commands common to
# OpenSTA, Synopsys tools and Vivado are used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists IIR_INST]} {
    puts "iir.sdc: IIR_INST is not set; nothing constrained"
    return
}
set _p [expr {$IIR_INST eq "" ? "" : "$IIR_INST/"}]

#-----------------------------------------------------------------------------
# The feedback loop is reported as its own group.
#-----------------------------------------------------------------------------
set _feedback [get_nets -quiet ${_p}m_data*]
if {[llength $_feedback] > 0} {
    group_path -name iir_feedback -through $_feedback
}
