#=============================================================================
# ip/arithmetic/subtractor
#
# Depends on adder: the difference is computed as a + ~b + ~borrow_in rather
# than with a second carry chain, so there is one implementation of two's
# complement addition in the portfolio.
#=============================================================================
add_ip(
  NAME            subtractor
  TOP             subtractor
  SOURCES         rtl/subtractor.sv
  DEPENDS         adder
  SVTB            tb/tb_subtractor.sv
  COCOTB_MODULES  test_subtractor
  PARAMS          WIDTH=16 SIGNED=1 SATURATE=1
  NO_STA
)
