#=============================================================================
# fifo_sync.sdc - constraints for the synchronous FIFO
#
# Usage from the integrating project:
#
#   set FIFO_INST [get_cells u_fifo]
#   source ip/memory/fifo_sync/scripts/fifo_sync.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists FIFO_INST]} {
    puts "fifo_sync.sdc: FIFO_INST is not set; nothing to constrain"
    return
}

#-----------------------------------------------------------------------------
# The block needs no timing exceptions.
#
# Everything is synchronous to one clock. The pointers, the occupancy counters
# and the show-ahead output stage are all ordinary single-cycle logic, and the
# storage is a ram_sdp with both ports on that same clock.
#
# This file exists for the notes below rather than for constraints.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Combinational paths worth knowing about.
#
# s_ready is combinational from the occupancy counters, and m_valid from the
# output-stage count. Both are short, but they are what connects a producer to
# a consumer through the FIFO, so in a design where the FIFO sits between two
# far-apart blocks they can become the critical path.
#
# The fix, if that happens, is a register slice on the offending side rather
# than a change to this block: breaking the ready path inside the FIFO would
# cost either throughput or capacity.
#-----------------------------------------------------------------------------
if {[info exists FIFO_CLK]} {
    set _period [get_property $FIFO_CLK period]
    foreach _pin {s_ready m_valid} {
        set _handle [get_pins -quiet ${FIFO_INST}/${_pin}]
        if {[sizeof_collection $_handle] > 0} {
            set_max_delay [expr {$_period * 0.5}] -to $_handle
        }
    }
}

#-----------------------------------------------------------------------------
# Storage inference - see ip/memory/ram_sp/scripts/ram_sp.sdc.
#-----------------------------------------------------------------------------
