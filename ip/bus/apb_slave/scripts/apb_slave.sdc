#=============================================================================
# apb_slave.sdc - timing constraints for the APB4 completer
#
# One clock domain and no exception: every path is an ordinary single-cycle
# path, and the APB protocol's own two-cycle minimum is not a multicycle
# path - PSEL, PADDR and PWRITE are sampled on the setup edge as well.
#
# Usage from the integrating project:
#
#   set APB_SLAVE_INST u_apb_slave
#   source ip/bus/apb_slave/scripts/apb_slave.sdc
#
# APB_SLAVE_INST is the instance's hierarchical name, not a cell object, and an empty
# string means the block is the top of the design. Source the file once per
# instance. Only commands common to OpenSTA, Synopsys tools and Vivado are
# used.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

if {![info exists APB_SLAVE_INST]} {
    puts "apb_slave.sdc: APB_SLAVE_INST is not set; nothing constrained"
    return
}
set _p [expr {$APB_SLAVE_INST eq "" ? "" : "$APB_SLAVE_INST/"}]

#-----------------------------------------------------------------------------
# The register response.
#
# With REGISTERED=0 the response is combinational: PADDR reaches the register
# block's read multiplexer through reg_addr and comes back through reg_rdata
# to PRDATA, inside one APB cycle and partly in logic outside this block.
# With REGISTERED=1 the same path ends at the response registers instead. In
# both, it is the path that sets the bus frequency, so it is reported as its
# own group. If it misses, REGISTERED=1 halves it.
#-----------------------------------------------------------------------------
set _response [get_nets -quiet [list ${_p}reg_rdata* ${_p}reg_ready ${_p}reg_error]]
if {[llength $_response] > 0} {
    group_path -name apb_slave_register_response -through $_response
}
