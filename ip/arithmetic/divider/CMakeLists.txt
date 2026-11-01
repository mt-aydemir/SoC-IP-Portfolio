#=============================================================================
# ip/arithmetic/divider
#
# Verified signed: it is the interpretation with the special cases - the
# truncated rounding of negative operands and most-negative / -1 - that the
# unsigned configuration never reaches.
#=============================================================================
add_ip(
  NAME            divider
  TOP             divider
  SOURCES         rtl/divider.sv
  SVTB            tb/tb_divider.sv
  COCOTB_MODULES  test_divider
  PARAMS          WIDTH=16 SIGNED=1
  CLOCK_PERIOD_NS 10.0
  CLOCK_PORT      clk
  STA_SDC         scripts/divider.sdc
)
