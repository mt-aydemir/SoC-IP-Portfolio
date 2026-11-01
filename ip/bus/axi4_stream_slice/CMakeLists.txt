#=============================================================================
# ip/bus/axi4_stream_slice
#
# A single add_ip() call registers the complete flow:
#   lint -> cocotb simulation + SystemVerilog testbench -> synthesis -> timing
#=============================================================================
add_ip(
  NAME            axi4_stream_slice
  TOP             axi4_stream_slice
  SOURCES         rtl/axi4_stream_slice.sv
  SVTB            tb/tb_axi4_stream_slice.sv
  COCOTB_MODULES  test_axi4_stream_slice
  PARAMS          MODE=3 DATA_WIDTH=32 ID_WIDTH=4 DEST_WIDTH=4 USER_WIDTH=2
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
  STA_SDC         scripts/axi4_stream_slice.sdc
)
