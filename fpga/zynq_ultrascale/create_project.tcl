#=============================================================================
# create_project.tcl - Zynq UltraScale+ reference design for cnn_accel
#
#   vivado -mode batch -source create_project.tcl
#   vivado -mode batch -source create_project.tcl -tclargs -board zcu102 -run
#
# Builds the block design below, and with -run takes it through implementation
# and exports the XSA that Vitis needs to generate the BSP.
#
#   +-------------------+        +------------+       +--------------+
#   | zynq_ultra_ps_e   |        |  axi_dma   |       |  cnn_accel   |
#   |                   | HPM0   |            | MM2S  |              |
#   |   M_AXI_HPM0_LPD  |------->| S_AXI_LITE |------>| s_axis       |
#   |                   |        |            |       |              |
#   |   S_AXI_HP0_FPD   |<-------| M_AXI_*    |  S2MM |              |
#   |                   |        |            |<------| m_axis       |
#   |   pl_clk0 250 MHz |------->|            |       |              |
#   +-------------------+        +------------+       +--------------+
#
# WHY THE DMA AND THE ACCELERATOR ARE IN THE SAME CLOCK DOMAIN
#   Both run off pl_clk0. Putting a clock crossing between them would need an
#   asynchronous FIFO on each stream and would buy nothing: the accelerator's
#   period is set by a DSP block's multiply-accumulate, which is comfortable at
#   250 MHz on a -2 part, and the DMA is comfortable there too. If a target
#   part cannot make the frequency, lower the PL clock rather than splitting
#   the domains.
#
# WHY THE STREAM IS 128 BITS
#   It is ARRAY_N * 8 - one int8 lane per array column - and it is also the
#   width of an HP port, so the DMA moves one activation vector per cycle with
#   no packing. That is the match that lets the array run at one vector per
#   cycle from DDR.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

set script_dir [file normalize [file dirname [info script]]]

#-----------------------------------------------------------------------------
# Options
#-----------------------------------------------------------------------------
set board      zcu104
set array_n    16
set clock_mhz  250
set run_impl   0
set jobs       8

for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        -board     { incr i; set board     [lindex $argv $i] }
        -array_n   { incr i; set array_n   [lindex $argv $i] }
        -clock_mhz { incr i; set clock_mhz [lindex $argv $i] }
        -jobs      { incr i; set jobs      [lindex $argv $i] }
        -run       { set run_impl 1 }
        default    { puts "create_project.tcl: ignoring [lindex $argv $i]" }
    }
}

# Board part and device. The PS configuration comes from the board preset,
# which is what makes the DDR and MIO settings right without reproducing a
# few hundred properties here.
switch -- $board {
    zcu104 { set part xczu7ev-ffvc1156-2-e ; set board_part xilinx.com:zcu104:part0:1.1 }
    zcu102 { set part xczu9eg-ffvb1156-2-e ; set board_part xilinx.com:zcu102:part0:3.4 }
    zcu106 { set part xczu7ev-ffvc1156-2-e ; set board_part xilinx.com:zcu106:part0:2.6 }
    kv260  { set part xck26-sfvc784-2LV-c  ; set board_part xilinx.com:kv260_som:part0:1.4 }
    default {
        puts "ERROR: unknown board '$board'. Known: zcu104 zcu102 zcu106 kv260"
        exit 1
    }
}

set stream_width [expr {$array_n * 8}]
set project_dir  $script_dir/build/$board
set project_name cnn_accel_${board}
set ip_repo      $script_dir/ip_repo/cnn_accel

if {![file isdirectory $ip_repo]} {
    puts "ERROR: $ip_repo does not exist."
    puts "       Run package_ip.tcl first."
    exit 1
}

file mkdir $project_dir

puts ""
puts "board        : $board ($part)"
puts "array        : ${array_n}x${array_n}, ${stream_width}-bit stream"
puts "PL clock     : ${clock_mhz} MHz"
puts "project      : $project_dir/$project_name"
puts ""

#-----------------------------------------------------------------------------
# Project
#-----------------------------------------------------------------------------
create_project $project_name $project_dir -part $part -force
set_property board_part $board_part [current_project]
set_property ip_repo_paths $ip_repo [current_project]
update_ip_catalog -rebuild

set design bd_cnn_accel
create_bd_design $design

#-----------------------------------------------------------------------------
# Processing system
#-----------------------------------------------------------------------------
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} $ps

# One PL clock, one HP slave for the DMA's memory traffic, one LPD master for
# its control registers. Everything else the preset configured stays as it is.
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0        {1} \
    CONFIG.PSU__USE__M_AXI_GP2        {0} \
    CONFIG.PSU__USE__S_AXI_GP2        {1} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH   {128} \
    CONFIG.PSU__USE__IRQ0             {1} \
    CONFIG.PSU__FPGA_PL0_ENABLE       {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $clock_mhz \
] $ps

#-----------------------------------------------------------------------------
# DMA
#
# Simple mode - no scatter-gather - because the reference driver polls one
# transfer per frame. The stream widths must match the accelerator exactly:
# the DMA has no data realignment engine enabled, so a mismatch is a
# connection error at validation rather than something discovered at run time.
#-----------------------------------------------------------------------------
set dma [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma axi_dma_0]
set_property -dict [list \
    CONFIG.c_include_sg               {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_include_mm2s_dre         {0} \
    CONFIG.c_include_s2mm_dre         {0} \
    CONFIG.c_sg_length_width          {26} \
    CONFIG.c_m_axi_mm2s_data_width    {128} \
    CONFIG.c_m_axis_mm2s_tdata_width  $stream_width \
    CONFIG.c_mm2s_burst_size          {256} \
    CONFIG.c_m_axi_s2mm_data_width    {128} \
    CONFIG.c_s_axis_s2mm_tdata_width  $stream_width \
    CONFIG.c_s2mm_burst_size          {256} \
] $dma

#-----------------------------------------------------------------------------
# The accelerator
#-----------------------------------------------------------------------------
set accel [create_bd_cell -type ip -vlnv socip:ml:cnn_accel:1.0 cnn_accel_0]
set_property -dict [list CONFIG.ARRAY_N $array_n] $accel

#-----------------------------------------------------------------------------
# Streams: DMA out to accelerator in, accelerator out to DMA in.
#-----------------------------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins $dma/M_AXIS_MM2S] \
                    [get_bd_intf_pins $accel/s_axis]
connect_bd_intf_net [get_bd_intf_pins $accel/m_axis] \
                    [get_bd_intf_pins $dma/S_AXIS_S2MM]

#-----------------------------------------------------------------------------
# Memory-mapped connections, left to the automation. It builds the
# interconnect, the reset network and the address map, and it gets the clock
# domains right - which is worth more than the control a hand-built
# interconnect would give here.
#-----------------------------------------------------------------------------
apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Master "/zynq_ultra_ps_e_0/M_AXI_HPM0_LPD" \
    Clk_master "Auto" Clk_slave "Auto" Clk_xbar "Auto" \
    Slave "/axi_dma_0/S_AXI_LITE" intc_ip "New AXI SmartConnect" \
    master_apm "0"] [get_bd_intf_pins $dma/S_AXI_LITE]

foreach mm {M_AXI_MM2S M_AXI_S2MM} {
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
        Clk_master "Auto" Clk_slave "Auto" Clk_xbar "Auto" \
        Master "/axi_dma_0/$mm" \
        Slave "/zynq_ultra_ps_e_0/S_AXI_HP0_FPD" \
        intc_ip "New AXI SmartConnect" master_apm "0"] \
        [get_bd_intf_pins $ps/S_AXI_HP0_FPD]
}

#-----------------------------------------------------------------------------
# Clock and reset for the accelerator. The automation above created the reset
# block; reuse it rather than adding a second one.
#-----------------------------------------------------------------------------
set rstn [get_bd_pins -quiet -of_objects [get_bd_cells -quiet -filter \
    {VLNV =~ "xilinx.com:ip:proc_sys_reset:*"}] -filter {NAME =~ "peripheral_aresetn"}]

connect_bd_net [get_bd_pins $ps/pl_clk0] [get_bd_pins $accel/clk]
if {[llength $rstn] > 0} {
    connect_bd_net [lindex $rstn 0] [get_bd_pins $accel/rst_n]
} else {
    puts "WARNING: no proc_sys_reset found; connect cnn_accel/rst_n by hand"
}

#-----------------------------------------------------------------------------
# Interrupts.
#
# The DMA's completion interrupts are what the driver would use if it were
# interrupt driven; the accelerator's own irq is exported as well. The
# reference driver polls, so none of this is required to run the demo - it is
# here because leaving an interrupt unrouted in a reference design is how it
# ends up unrouted in a product.
#-----------------------------------------------------------------------------
set concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat irq_concat]
set_property CONFIG.NUM_PORTS {3} $concat

connect_bd_net [get_bd_pins $dma/mm2s_introut] [get_bd_pins $concat/In0]
connect_bd_net [get_bd_pins $dma/s2mm_introut] [get_bd_pins $concat/In1]
connect_bd_net [get_bd_pins $accel/irq]        [get_bd_pins $concat/In2]
connect_bd_net [get_bd_pins $concat/dout]      [get_bd_pins $ps/pl_ps_irq0]

# Status bits brought out so they can be probed with an ILA during bring-up,
# which is the difference between "it hangs" and "it raised a framing error on
# the third tile".
foreach {pin name} {error cnn_accel_error busy cnn_accel_busy} {
    create_bd_port -dir O $name
    connect_bd_net [get_bd_pins $accel/$pin] [get_bd_ports $name]
}

#-----------------------------------------------------------------------------
# Finish the block design
#-----------------------------------------------------------------------------
assign_bd_address
regenerate_bd_layout
validate_bd_design
save_bd_design

make_wrapper -files [get_files $design.bd] -top
add_files -norecurse $project_dir/$project_name.gen/sources_1/bd/$design/hdl/${design}_wrapper.v
set_property top ${design}_wrapper [current_fileset]

add_files -fileset constrs_1 -norecurse $script_dir/constraints/cnn_accel.xdc
update_compile_order -fileset sources_1

puts ""
puts "block design built and validated."
puts "address map:"
puts [report_bd_address -force -return_string]

#-----------------------------------------------------------------------------
# Implementation
#-----------------------------------------------------------------------------
if {$run_impl} {
    launch_runs impl_1 -to_step write_bitstream -jobs $jobs
    wait_on_run impl_1

    if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
        puts "ERROR: implementation did not complete"
        exit 1
    }

    open_run impl_1

    puts ""
    puts "=== timing ==="
    puts [report_timing_summary -no_detailed_paths -return_string]
    puts ""
    puts "=== utilisation ==="
    puts [report_utilization -return_string]

    set wns [get_property SLACK [get_timing_paths -delay_type max]]
    set whs [get_property SLACK [get_timing_paths -delay_type min]]
    puts ""
    puts "worst setup slack: $wns ns"
    puts "worst hold slack : $whs ns"
    if {$wns < 0 || $whs < 0} {
        puts "TIMING NOT MET - lower -clock_mhz or see constraints/cnn_accel.xdc"
    }

    set xsa $project_dir/${project_name}.xsa
    write_hw_platform -fixed -include_bit -force -file $xsa
    puts ""
    puts "XSA written: $xsa"
    puts "Generate the BSP from it in Vitis, then:"
    puts "  make -C ../../sw/cnn_accel app BSP=<bsp>/psu_cortexa53_0"
}

puts ""
puts "done."
