#=============================================================================
# ip/ml/cnn_accel
#
# The accelerator top. Depends on the array, the requantiser and two memory
# blocks, all of which are registered before the ml category is added.
#
# Simulated at the deployment size: the pipeline latency, the credit
# accounting and the accumulator addressing are all functions of ARRAY_N, so a
# smaller build would not exercise the same arithmetic. The SystemVerilog
# testbench runs an 8 by 8 build instead, which keeps a second geometry under
# test at a fraction of the compile time.
#
# NO_STA: the accumulator buffer (ACC_DEPTH x ARRAY_N x 32 bits) and the
# output FIFO are flip-flop arrays in this vendor-independent flow, so single
# minimum-size cells drive thousands of loads and OpenSTA reports slacks of
# around -2000 ns that describe the generic library, not the design - the same
# reason ram_sp and bram_ctrl are not timed. In an implementation those
# arrays are block RAM. The datapath the accelerator adds is timed through its
# components: systolic_pe, systolic_array and requant_int8 all run STA.
#=============================================================================
add_ip(
  NAME            cnn_accel
  TOP             cnn_accel
  SOURCES         rtl/cnn_accel_ctrl.sv
                  rtl/cnn_accel.sv
  DEPENDS         ram_sdp fifo_sync systolic_pe systolic_array requant_int8
  SVTB            tb/tb_cnn_accel.sv
  COCOTB_MODULES  test_cnn_accel
  PARAMS          ARRAY_N=16 ACC_DEPTH=256 OUT_FIFO_DEPTH=64
  CLOCK_PERIOD_NS 4.0
  CLOCK_PORT      clk
  NO_STA
)
