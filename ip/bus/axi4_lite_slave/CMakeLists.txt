#=============================================================================
# ip/bus/axi4_lite_slave
#
# A single add_ip() call registers the complete flow:
#   lint -> cocotb simulation + SystemVerilog testbench -> synthesis -> timing
#=============================================================================
add_ip(
  NAME            axi4_lite_slave
  TOP             axi4_lite_slave
  SOURCES         rtl/axi4_lite_slave.sv
  SVTB            tb/tb_axi4_lite_slave.sv
  COCOTB_MODULES  test_axi4_lite_slave
  PARAMS          ADDR_WIDTH=12 DATA_WIDTH=32
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
  STA_SDC         scripts/axi4_lite_slave.sdc
  FORMAL_TOP      axi4_lite_slave_formal
  FORMAL_SOURCES  formal/axi4_lite_slave_formal.sv
  FORMAL_DEPTH    10
)
