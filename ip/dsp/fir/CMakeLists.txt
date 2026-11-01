#=============================================================================
# ip/dsp/fir
#
# A single add_ip() call registers the complete flow:
#   lint -> cocotb simulation + SystemVerilog testbench -> synthesis -> timing
#=============================================================================
add_ip(
  NAME            fir
  TOP             fir
  SOURCES         rtl/fir.sv
  SVTB            tb/tb_fir.sv
  COCOTB_MODULES  test_fir
  PARAMS          TAPS=8 DATA_WIDTH=12 COEF_WIDTH=10
  CLOCK_PERIOD_NS 10.0
  CLOCK_PORT      clk
  STA_SDC         scripts/fir.sdc
)
