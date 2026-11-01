#=============================================================================
# examples/nco - a quadrature oscillator from accumulator and cordic
#
# Registered like any IP so that it lints, simulates, synthesises and is timed
# on every regression: an example that no longer compiles against the blocks
# it demonstrates is worse than no example.
#=============================================================================
add_ip(
  NAME            nco
  TOP             nco
  SOURCES         rtl/nco.sv
  DEPENDS         accumulator cordic
  COCOTB_MODULES  test_nco
  PARAMS          WIDTH=16 ITERATIONS=16
  CLOCK_PERIOD_NS 10.0
  CLOCK_PORT      clk
)
