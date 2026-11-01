#=============================================================================
# fir.sdc - timing constraints for the transposed-form FIR
#
# One clock domain and no exception. The coefficients are quasi-static, but
# a write takes effect on the next sample, so the coefficient-to-product path
# is a real single-cycle path and no multicycle constraint may be applied.
#
# Usage from the integrating project:
#
#   set FIR_INST u_fir
#   source ip/dsp/fir/scripts/fir.sdc
#
# FIR_INST is the instance's hierarchical name, not a cell object, and an empty
# string means the block is the top of the design. Only commands common to
# OpenSTA, Synopsys tools and Vivado are used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists FIR_INST]} {
    puts "fir.sdc: FIR_INST is not set; nothing constrained"
    return
}
set _p [expr {$FIR_INST eq "" ? "" : "$FIR_INST/"}]

#-----------------------------------------------------------------------------
# The critical path is one multiplier and one adder into a partial-sum
# register, the same for every tap. The input sample fans out to all TAPS
# multipliers; that net is reported as its own group because its fanout, not
# its logic depth, is what grows with TAPS.
#-----------------------------------------------------------------------------
set _sample [get_nets -quiet ${_p}s_data*]
if {[llength $_sample] > 0} {
    group_path -name fir_sample_fanout -through $_sample
}
