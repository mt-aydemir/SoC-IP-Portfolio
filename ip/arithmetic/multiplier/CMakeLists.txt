#=============================================================================
# ip/arithmetic/multiplier
#
# Verified signed with two pipeline stages: signed is the interpretation that
# needs the explicit sign extension, and two stages is the shallowest depth at
# which an off-by-one in the valid pipeline is distinguishable from the
# LATENCY = 1 case that the loop-based shift register exists to support.
#=============================================================================
add_ip(
  NAME            multiplier
  TOP             multiplier
  SOURCES         rtl/multiplier.sv
  SVTB            tb/tb_multiplier.sv
  COCOTB_MODULES  test_multiplier
  PARAMS          A_WIDTH=16 B_WIDTH=16 SIGNED=1 LATENCY=2
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
)
