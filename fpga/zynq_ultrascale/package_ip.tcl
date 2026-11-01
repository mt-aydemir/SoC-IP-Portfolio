#=============================================================================
# package_ip.tcl - package cnn_accel as an IP-XACT core for Vivado IP integrator
#
#   vivado -mode batch -source package_ip.tcl
#   vivado -mode batch -source package_ip.tcl -tclargs -array_n 32
#
# Produces an IP repository under ip_repo/cnn_accel that create_project.tcl
# adds to its project.
#
# The RTL is portfolio RTL: no vendor primitives, no vendor attributes. Nothing
# here modifies it. Packaging is entirely a matter of telling IP integrator
# which ports form which interface, and the only reason it is not fully
# automatic is the reset polarity - the inference defaults to active high, and
# an active-low reset held low by an active-high assumption produces a design
# that never comes out of reset and gives no hint why.
#
# Copyright (c) 2026 SoC IP Portfolio Contributors
# SPDX-License-Identifier: Apache-2.0
#=============================================================================

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize $script_dir/../..]

#-----------------------------------------------------------------------------
# Options
#-----------------------------------------------------------------------------
set array_n        16
set acc_depth      256
set out_fifo_depth 64
set part           xczu7ev-ffvc1156-2-e

for {set i 0} {$i < [llength $argv]} {incr i} {
    switch -- [lindex $argv $i] {
        -array_n        { incr i; set array_n        [lindex $argv $i] }
        -acc_depth      { incr i; set acc_depth      [lindex $argv $i] }
        -out_fifo_depth { incr i; set out_fifo_depth [lindex $argv $i] }
        -part           { incr i; set part           [lindex $argv $i] }
        default         { puts "package_ip.tcl: ignoring [lindex $argv $i]" }
    }
}

set stream_width [expr {$array_n * 8}]
if {$stream_width != 32 && $stream_width != 64 && $stream_width != 128 &&
    $stream_width != 256 && $stream_width != 512} {
    puts "ERROR: ARRAY_N=$array_n gives a ${stream_width}-bit stream, which is"
    puts "       not a width AXI4-Stream infrastructure IP supports. Use 8, 16,"
    puts "       32 or 64."
    exit 1
}

set ip_dir $script_dir/ip_repo/cnn_accel
file mkdir $ip_dir

puts "packaging cnn_accel: ARRAY_N=$array_n, ${stream_width}-bit stream"

#-----------------------------------------------------------------------------
# A throwaway project to elaborate the sources in.
#-----------------------------------------------------------------------------
create_project -in_memory -part $part

set sources [list \
    $repo_root/ip/memory/ram_sdp/rtl/ram_sdp.sv \
    $repo_root/ip/memory/fifo_sync/rtl/fifo_sync.sv \
    $repo_root/ip/ml/systolic_pe/rtl/systolic_pe.sv \
    $repo_root/ip/ml/systolic_array/rtl/systolic_array.sv \
    $repo_root/ip/ml/requant_int8/rtl/requant_int8.sv \
    $repo_root/ip/ml/cnn_accel/rtl/cnn_accel_ctrl.sv \
    $repo_root/ip/ml/cnn_accel/rtl/cnn_accel.sv ]

add_files -norecurse $sources
set_property file_type SystemVerilog [get_files *.sv]
set_property top cnn_accel [current_fileset]
update_compile_order -fileset sources_1

#-----------------------------------------------------------------------------
# Package
#-----------------------------------------------------------------------------
ipx::package_project -root_dir $ip_dir -vendor socip -library ml \
    -taxonomy /Embedded_Processing/AI -import_files -force

set core [ipx::current_core]

set_property name         cnn_accel                                    $core
set_property display_name "Quantised int8 CNN inference accelerator"   $core
set_property description  "Systolic int8 matrix-multiply array with an accumulator buffer and per-channel requantisation, driven over AXI4-Stream" $core
set_property vendor_display_name "SoC IP Portfolio"                    $core
set_property company_url  "https://example.invalid/soc-ip-portfolio"   $core
set_property version      1.0                                          $core
set_property core_revision 1                                           $core
set_property supported_families {zynquplus Production zynqultrascaleplus Production} $core

#-----------------------------------------------------------------------------
# Parameter defaults and what a user may change.
#
# ARRAY_N is exposed but the stream width is derived from it, so IP integrator
# has to be told the dependency or it will offer a legal parameter that
# produces an illegal interface.
#-----------------------------------------------------------------------------
foreach {name value} [list ARRAY_N $array_n ACC_DEPTH $acc_depth \
                           OUT_FIFO_DEPTH $out_fifo_depth] {
    set param [ipx::get_user_parameters $name -of_objects $core]
    if {[llength $param] == 0} {
        puts "WARNING: parameter $name was not inferred from the RTL"
        continue
    }
    set_property value $value $param
    set_property value $value [ipx::get_hdl_parameters $name -of_objects $core]
}

set p [ipx::get_user_parameters ARRAY_N -of_objects $core]
if {[llength $p] > 0} {
    set_property widget {comboBox}   [ipgui::get_guiparamspec -name ARRAY_N -component $core]
    set_property value_validation_type list           $p
    set_property value_validation_list {8 16 32 64}   $p
}

#-----------------------------------------------------------------------------
# Interfaces.
#
# The stream ports are named to the AXI4-Stream convention, so inference finds
# them. The clock and reset are portfolio-named - clk and rst_n - which
# inference also handles, except for the polarity.
#-----------------------------------------------------------------------------
ipx::infer_bus_interfaces xilinx.com:interface:axis_rtl:1.0 $core
ipx::infer_bus_interface  clk   xilinx.com:signal:clock_rtl:1.0 $core
ipx::infer_bus_interface  rst_n xilinx.com:signal:reset_rtl:1.0 $core

# The one thing inference gets wrong. An active-low reset packaged as active
# high is held asserted by a correctly connected processor reset block, and the
# design simply never starts.
set reset_if [ipx::get_bus_interfaces rst_n -of_objects $core]
set_property value ACTIVE_LOW \
    [ipx::get_bus_parameters POLARITY -of_objects $reset_if]

# Tie the streams and the reset to the clock, so IP integrator knows they are
# synchronous to it and the automation connects them without asking.
ipx::associate_bus_interfaces -busif s_axis -clock clk $core
ipx::associate_bus_interfaces -busif m_axis -clock clk $core
ipx::associate_bus_interfaces -busif rst_n  -clock clk $core

#-----------------------------------------------------------------------------
# Sideband ports. Left as plain signals rather than dressed up as an
# interrupt interface, because irq is a one-cycle pulse in the accelerator's
# clock domain and how it should reach the processor depends on the design.
#-----------------------------------------------------------------------------
foreach port {irq error busy} {
    set obj [ipx::get_ports $port -of_objects $core]
    if {[llength $obj] > 0} {
        set_property enablement_dependency {} $obj
    }
}

#-----------------------------------------------------------------------------
# Write it out
#-----------------------------------------------------------------------------
ipx::create_xgui_files       $core
ipx::update_checksums        $core
ipx::check_integrity         $core
ipx::save_core               $core
ipx::archive_core            $ip_dir/socip_ml_cnn_accel_1.0.zip $core

puts ""
puts "packaged: $ip_dir"
puts "add it with:  set_property ip_repo_paths $ip_dir \[current_project\]"
puts ""

close_project
