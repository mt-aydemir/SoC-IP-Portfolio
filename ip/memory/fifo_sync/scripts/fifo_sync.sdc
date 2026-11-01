#=============================================================================
# fifo_sync.sdc - constraints for the synchronous FIFO
#
# Usage from the integrating project:
#
#   set FIFO_INST u_fifo
#   source ip/memory/fifo_sync/scripts/fifo_sync.sdc
#
# FIFO_INST is the instance's hierarchical name, not a cell object, and an empty
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

if {![info exists FIFO_INST]} {
    puts "fifo_sync.sdc: FIFO_INST is not set; nothing constrained"
    return
}
set _p [expr {$FIFO_INST eq "" ? "" : "$FIFO_INST/"}]

#-----------------------------------------------------------------------------
# The block needs no timing exceptions.
#
# Everything is synchronous to one clock. The pointers, the occupancy counters
# and the show-ahead output stage are all ordinary single-cycle logic, and the
# storage is a ram_sdp with both ports on that same clock.
#-----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# Combinational paths worth knowing about.
#
# s_ready is combinational from the occupancy counters, and m_valid from the
# output-stage count. Both are short, but they are what connects a producer to
# a consumer through the FIFO, so in a design where the FIFO sits between two
# far-apart blocks they can become the critical path. Each is reported as its
# own path group, so a timing report names it.
#
# The fix, if that happens, is a register slice on the offending side rather
# than a change to this block: breaking the ready path inside the FIFO would
# cost either throughput or capacity.
#-----------------------------------------------------------------------------
foreach _port {s_ready m_valid} {
    set _net [get_nets -quiet ${_p}${_port}]
    if {[llength $_net] > 0} {
        group_path -name fifo_sync_${_port} -through $_net
    }
}

#-----------------------------------------------------------------------------
# Storage inference - see ip/memory/ram_sp/scripts/ram_sp.sdc.
#-----------------------------------------------------------------------------
