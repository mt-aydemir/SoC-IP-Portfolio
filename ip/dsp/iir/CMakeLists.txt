#=============================================================================
# ip/dsp/iir
#
# A single add_ip() call registers the complete flow:
#   lint -> cocotb simulation + SystemVerilog testbench -> synthesis -> timing
#=============================================================================
add_ip(
  NAME            iir
  TOP             iir
  SOURCES         rtl/iir.sv
  SVTB            tb/tb_iir.sv
  COCOTB_MODULES  test_iir
  PARAMS          DATA_WIDTH=12 COEF_WIDTH=12 COEF_FRAC=10
  CLOCK_PERIOD_NS 10.0
  CLOCK_PORT      clk
  STA_SDC         scripts/iir.sdc
)
