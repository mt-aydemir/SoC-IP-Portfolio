#=============================================================================
# ip/arithmetic/adder
#
# Verified in the signed, saturating configuration: it is the one in which
# every output is non-trivial. The cocotb reference model follows the
# parameters, so the same suite verifies wrap-around when SATURATE is 0.
#=============================================================================
add_ip(
  NAME            adder
  TOP             adder
  SOURCES         rtl/adder.sv
  SVTB            tb/tb_adder.sv
  COCOTB_MODULES  test_adder
  PARAMS          WIDTH=16 SIGNED=1 SATURATE=1
  NO_STA
)
