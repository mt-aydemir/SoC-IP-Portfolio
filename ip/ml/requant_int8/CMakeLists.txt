#=============================================================================
# ip/ml/requant_int8
#
# Timed at 6.5 ns rather than the accelerator's 4 ns FPGA target. On the
# portfolio's generic library (one drive strength, adders mapped as ripple
# carry, no timing-driven mapping) stage 3 - round, shift, offset and clamp
# across the 58-bit product - measures about 5.5 ns. On an FPGA the same
# stage maps onto carry chains and closes at 250 MHz; on this library it does
# not, and the honest number is the one recorded here. Splitting stage 3 is
# the fix if a 4 ns ASIC target is ever wanted; it costs one cycle of latency,
# which cnn_accel's credit accounting would have to absorb.
#=============================================================================
add_ip(
  NAME            requant_int8
  TOP             requant_int8
  SOURCES         rtl/requant_int8.sv
  SVTB            tb/tb_requant_int8.sv
  COCOTB_MODULES  test_requant_int8
  PARAMS          ACC_WIDTH=32 MULT_WIDTH=24 SHIFT_WIDTH=6 OUT_WIDTH=8
  CLOCK_PERIOD_NS 6.5
  CLOCK_PORT      clk
  STA_SDC         scripts/requant_int8.sdc
  SDC_INST_VAR    REQUANT_INST
)
