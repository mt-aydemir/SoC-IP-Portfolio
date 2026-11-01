#=============================================================================
# ip/clocking/clk_divider
#
# Verified at DIVISOR=5: an odd ratio is the case that exposes a duty cycle
# wrong by half a source period, so it is the default the flow exercises.
#=============================================================================
add_ip(
  NAME            clk_divider
  TOP             clk_divider
  SOURCES         rtl/clk_divider.sv
  SVTB            tb/tb_clk_divider.sv
  COCOTB_MODULES  test_clk_divider
  PARAMS          DIVISOR=5
  CLOCK_PERIOD_NS 10.0
  CLOCK_PORT      clk
  STA_SDC         scripts/clk_divider.sdc
  SDC_INST_VAR    DIV_INST
  SDC_VARS        "DIV_RATIO=5"
  FORMAL_MULTICLOCK
  FORMAL_TOP      clk_divider_formal
  FORMAL_SOURCES  formal/clk_divider_formal.sv
  FORMAL_DEPTH    30
)
