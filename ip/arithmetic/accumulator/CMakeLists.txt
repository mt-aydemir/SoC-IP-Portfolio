#=============================================================================
# ip/arithmetic/accumulator
#
# Verified signed and saturating: the configuration in which every output is
# non-trivial. The reference models follow the parameters, so the same suites
# verify wrap-around and the unsigned limits at the other settings.
#=============================================================================
add_ip(
  NAME            accumulator
  TOP             accumulator
  SOURCES         rtl/accumulator.sv
  SVTB            tb/tb_accumulator.sv
  COCOTB_MODULES  test_accumulator
  PARAMS          DATA_WIDTH=16 ACC_WIDTH=32 SIGNED=1 SATURATE=1
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
  STA_SDC         scripts/accumulator.sdc
)
