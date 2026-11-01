#=============================================================================
# ip/crypto/sha256
#
# A single add_ip() call registers the complete flow:
#   lint -> cocotb simulation + SystemVerilog testbench -> synthesis -> timing
#=============================================================================
add_ip(
  NAME            sha256
  TOP             sha256
  SOURCES         rtl/sha256.sv
  SVTB            tb/tb_sha256.sv
  COCOTB_MODULES  test_sha256
  CLOCK_PERIOD_NS 10.0
  CLOCK_PORT      clk
  STA_SDC         scripts/sha256.sdc
)
