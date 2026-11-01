#=============================================================================
# ip/<category>/template_ip
#
# A single add_ip() call registers the complete flow:
#   lint -> cocotb simulation + SystemVerilog testbench -> synthesis -> timing
#=============================================================================
add_ip(
  NAME            template_ip
  TOP             template_ip
  SOURCES         rtl/template_ip.sv
  SVTB            tb/tb_template_ip.sv
  COCOTB_MODULES  test_template_ip
  PARAMS          DATA_WIDTH=8
  CLOCK_PERIOD_NS 10.0
  CLOCK_PORT      clk
)
