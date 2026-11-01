#=============================================================================
# fft.sdc - timing constraints for the burst FFT
#
# One clock domain and no exception. Each butterfly reads, computes and
# writes back in one cycle, and the next butterfly may read what it wrote,
# so the butterfly is a genuine single-cycle path.
#
# Usage from the integrating project:
#
#   set FFT_INST u_fft
#   source ip/dsp/fft/scripts/fft.sdc
#
# FFT_INST is the instance's hierarchical name, not a cell object, and an empty
# string means the block is the top of the design. Only commands common to
# OpenSTA, Synopsys tools and Vivado are used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists FFT_INST]} {
    puts "fft.sdc: FFT_INST is not set; nothing constrained"
    return
}
set _p [expr {$FFT_INST eq "" ? "" : "$FFT_INST/"}]

#-----------------------------------------------------------------------------
# The critical path is the butterfly: the N:1 read multiplexer, a complex
# multiply, the sums, halving and saturation. The twiddle ROM output is
# reported as its own group, so a report separates the ROM and multiplier
# from the memory multiplexer.
#-----------------------------------------------------------------------------
set _twiddle [get_nets -quiet [list ${_p}w_cos* ${_p}w_sin*]]
if {[llength $_twiddle] > 0} {
    group_path -name fft_twiddle_multiply -through $_twiddle
}
