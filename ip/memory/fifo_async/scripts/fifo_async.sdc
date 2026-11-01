#=============================================================================
# fifo_async.sdc - constraints for the asynchronous FIFO
#
# Usage from the integrating project:
#
#   set FIFO_INST   [get_cells u_cdc_fifo]
#   set FIFO_WR_CLK [get_clocks clk_wr]
#   set FIFO_RD_CLK [get_clocks clk_rd]
#   source ip/memory/fifo_async/scripts/fifo_async.sdc
#
# This is the one file in the memory category whose constraints are load
# bearing. Without them the pointer crossings are either left unanalysed by
# accident or, worse, analysed as if the clocks were related.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists FIFO_INST]} {
    puts "fifo_async.sdc: FIFO_INST is not set; constraining every instance"
    set FIFO_INST [get_cells -hierarchical -filter {REF_NAME =~ fifo_async*}]
}

#-----------------------------------------------------------------------------
# 1. Declare the two clocks asynchronous.
#
# This single statement removes every cross-domain path in the block, including
# ones the instance-level constraints below would miss.
#-----------------------------------------------------------------------------
if {[info exists FIFO_WR_CLK] && [info exists FIFO_RD_CLK]} {
    set_clock_groups -asynchronous -group $FIFO_WR_CLK -group $FIFO_RD_CLK
}

#-----------------------------------------------------------------------------
# 2. Bound the delay on each pointer crossing.
#
# set_clock_groups removes the timing check, which is correct, but it also lets
# the tool route the pointer bus arbitrarily badly. Gray coding guarantees that
# a sample taken mid-transition yields either the old value or the new one -
# but only if the bits arrive within one destination clock period of each
# other. Skew larger than that breaks the guarantee, and the failure is a
# corrupted pointer, which means a FIFO that reports the wrong occupancy.
#
# -datapath_only excludes clock skew and jitter, making this a pure
# interconnect-delay bound rather than a setup check in disguise.
#-----------------------------------------------------------------------------
set _rd_first [get_cells -quiet ${FIFO_INST}/u_sync_rd_ptr/sync_q_reg*0*]
set _wr_first [get_cells -quiet ${FIFO_INST}/u_sync_wr_ptr/sync_q_reg*0*]

if {[info exists FIFO_WR_CLK] && [sizeof_collection $_rd_first] > 0} {
    set_max_delay -datapath_only [get_property $FIFO_WR_CLK period] \
                  -to [get_pins -quiet ${_rd_first}/D]
}
if {[info exists FIFO_RD_CLK] && [sizeof_collection $_wr_first] > 0} {
    set_max_delay -datapath_only [get_property $FIFO_RD_CLK period] \
                  -to [get_pins -quiet ${_wr_first}/D]
}

#-----------------------------------------------------------------------------
# 3. The memory data path.
#
# Data written in the write domain is read in the read domain with no
# synchroniser, which is safe because the pointer handshake guarantees a word
# is only read after its write has been visible for at least SYNC_STAGES read
# cycles. Bound it anyway, for the same reason as the pointers: without a
# bound the tool may route the data bus far more slowly than that window.
#-----------------------------------------------------------------------------
if {[info exists FIFO_RD_CLK]} {
    set _mem [get_cells -quiet ${FIFO_INST}/u_storage/mem_reg*]
    set _out [get_cells -quiet ${FIFO_INST}/u_storage/read_data_reg*]
    if {[sizeof_collection $_mem] > 0 && [sizeof_collection $_out] > 0} {
        set_max_delay -datapath_only [get_property $FIFO_RD_CLK period] \
                      -from $_mem -to $_out
    }
}

#-----------------------------------------------------------------------------
# 4. Preserve both synchroniser chains.
#
# See ip/cdc/sync_2ff/scripts/cdc_sync_2ff.sdc for the per-tool commands.
#-----------------------------------------------------------------------------
