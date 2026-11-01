#=============================================================================
# ip/dsp/cic
#
# A single add_ip() call registers the complete flow:
#   lint -> cocotb simulation + SystemVerilog testbench -> synthesis -> timing
#=============================================================================
add_ip(
  NAME            cic
  TOP             cic
  SOURCES         rtl/cic.sv
  SVTB            tb/tb_cic.sv
  COCOTB_MODULES  test_cic
  PARAMS          STAGES=4 MAX_RATE=16 DIFF_DELAY=1 DATA_WIDTH=12
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
  STA_SDC         scripts/cic.sdc
)
