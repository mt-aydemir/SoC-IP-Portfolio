#=============================================================================
# ip/arithmetic/cordic
#
# Verified at sixteen bits and sixteen iterations: the usual sine/cosine
# generator configuration, and the point past which more iterations stop
# improving the result because accuracy is about one bit per step.
#=============================================================================
add_ip(
  NAME            cordic
  TOP             cordic
  SOURCES         rtl/cordic.sv
  SVTB            tb/tb_cordic.sv
  COCOTB_MODULES  test_cordic
  PARAMS          WIDTH=16 ITERATIONS=16
  CLOCK_PERIOD_NS 10.0
  CLOCK_PORT      clk
)
