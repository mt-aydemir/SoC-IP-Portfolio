#=============================================================================
# ip/crypto/lfsr_rng
#
# A single add_ip() call registers the complete flow:
#   lint -> cocotb simulation + SystemVerilog testbench -> synthesis -> timing
#=============================================================================
add_ip(
  NAME            lfsr_rng
  TOP             lfsr_rng
  SOURCES         rtl/lfsr_rng.sv
  SVTB            tb/tb_lfsr_rng.sv
  COCOTB_MODULES  test_lfsr_rng
  PARAMS          WIDTH=32 STEPS=8
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
  STA_SDC         scripts/lfsr_rng.sdc
  FORMAL_TOP      lfsr_rng_formal
  FORMAL_SOURCES  formal/lfsr_rng_formal.sv
)
