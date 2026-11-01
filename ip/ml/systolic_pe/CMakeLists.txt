#=============================================================================
# ip/ml/systolic_pe
#=============================================================================
add_ip(
  NAME            systolic_pe
  TOP             systolic_pe
  SOURCES         rtl/systolic_pe.sv
  SVTB            tb/tb_systolic_pe.sv
  COCOTB_MODULES  test_systolic_pe
  PARAMS          DATA_WIDTH=8 ACC_WIDTH=32
  CLOCK_PERIOD_NS 4.0
  CLOCK_PORT      clk
)
