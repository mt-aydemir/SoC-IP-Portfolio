#=============================================================================
# ip/ml/mac_array
#
# A single add_ip() call registers the complete flow:
#   lint -> cocotb simulation + SystemVerilog testbench -> synthesis -> timing
#
# The cocotb run uses unsigned activations against signed weights, the usual
# quantised case; the SV testbench covers a padded tree and a wrapping
# accumulator at a second configuration.
#=============================================================================
add_ip(
  NAME            mac_array
  TOP             mac_array
  SOURCES         rtl/mac_array.sv
  SVTB            tb/tb_mac_array.sv
  COCOTB_MODULES  test_mac_array
  PARAMS          LANES=16 DATA_WIDTH=8 ACC_WIDTH=32 A_SIGNED=0 B_SIGNED=1
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
  STA_SDC         scripts/mac_array.sdc
  FORMAL_TOP      mac_array_formal
  FORMAL_SOURCES  formal/mac_array_formal.sv
  FORMAL_DEPTH    10
)
