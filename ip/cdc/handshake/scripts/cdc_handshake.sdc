#=============================================================================
# cdc_handshake.sdc - constraints for the request/acknowledge data crossing
#
# Three things must be declared here. The first two are the usual control
# crossings. The third - the payload path - is the one that is easy to forget,
# because it crosses domains with no synchroniser at all. That is by design:
# the payload register is provably static while the destination reads it, so it
# needs no synchroniser, but it still needs a constraint or the tool will try
# to time it between unrelated clocks.
#
# Usage from the integrating project:
#
#   set HS_INST    [get_cells u_cfg_cross]
#   set HS_SRC_CLK [get_clocks clk_cpu]
#   set HS_DST_CLK [get_clocks clk_dsp]
#   source ip/cdc/handshake/scripts/cdc_handshake.sdc
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists HS_INST]} {
    puts "cdc_handshake.sdc: HS_INST is not set; constraining every instance"
    set HS_INST [get_cells -hierarchical -filter {REF_NAME =~ cdc_handshake*}]
}

#-----------------------------------------------------------------------------
# 1. Declare the two clocks asynchronous.
#-----------------------------------------------------------------------------
if {[info exists HS_SRC_CLK] && [info exists HS_DST_CLK]} {
    set_clock_groups -asynchronous -group $HS_SRC_CLK -group $HS_DST_CLK
}

#-----------------------------------------------------------------------------
# 2. Bound the delay into each control synchroniser.
#-----------------------------------------------------------------------------
set _req_first [get_cells -quiet ${HS_INST}/u_sync_req/sync_q_reg*0*]
set _ack_first [get_cells -quiet ${HS_INST}/u_sync_ack/sync_q_reg*0*]

if {[info exists HS_DST_CLK] && [sizeof_collection $_req_first] > 0} {
    set_max_delay -datapath_only [get_property $HS_DST_CLK period] \
                  -to [get_pins -quiet ${_req_first}/D]
}

if {[info exists HS_SRC_CLK] && [sizeof_collection $_ack_first] > 0} {
    set_max_delay -datapath_only [get_property $HS_SRC_CLK period] \
                  -to [get_pins -quiet ${_ack_first}/D]
}

#-----------------------------------------------------------------------------
# 3. The payload path.
#
# payload_q is clocked by src_clk and captured into dst_data by dst_clk with no
# synchroniser between them. The protocol guarantees payload_q has been stable
# for at least STAGES destination cycles before that capture happens, so there
# is no metastability risk and no setup relationship worth analysing.
#
# It still needs a bound. Without one the tool may route the bus arbitrarily
# badly, and a payload bit arriving later than the STAGES-cycle stability
# window would be sampled while still in transit. Bounding the path at one
# destination clock period keeps the whole bus inside the window with margin.
#-----------------------------------------------------------------------------
set _payload [get_cells -quiet ${HS_INST}/payload_q_reg*]
set _capture [get_cells -quiet ${HS_INST}/dst_data_reg*]

if {[sizeof_collection $_payload] > 0 && [sizeof_collection $_capture] > 0} {
    if {[info exists HS_DST_CLK]} {
        set_max_delay -datapath_only [get_property $HS_DST_CLK period] \
                      -from [get_pins -quiet ${_payload}/C] \
                      -to   [get_pins -quiet ${_capture}/D]
    } else {
        set_false_path -from [get_pins -quiet ${_payload}/C] \
                       -to   [get_pins -quiet ${_capture}/D]
    }
}

#-----------------------------------------------------------------------------
# 4. Preserve both synchroniser chains.
#
# See ip/cdc/sync_2ff/scripts/cdc_sync_2ff.sdc for the per-tool commands.
#-----------------------------------------------------------------------------
