#=============================================================================
# ip/ml/systolic_array
#
# Simulated at the deployment size rather than a token one: the skew and
# deskew depths are functions of ROWS and COLS, so a small array does not
# exercise the alignment that a large one does.
#=============================================================================
add_ip(
  NAME            systolic_array
  TOP             systolic_array
  SOURCES         rtl/systolic_array.sv
  DEPENDS         systolic_pe
  SVTB            tb/tb_systolic_array.sv
  COCOTB_MODULES  test_systolic_array
  PARAMS          ROWS=16 COLS=16 DATA_WIDTH=8 ACC_WIDTH=32
  CLOCK_PERIOD_NS 4.0
  CLOCK_PORT      clk
)
