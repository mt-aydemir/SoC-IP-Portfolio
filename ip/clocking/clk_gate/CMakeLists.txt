#=============================================================================
# ip/clocking/clk_gate
#
# NO_STA: the block is a clock gate, not a data path. Its output is a
# generated clock that the integrating project must declare; timing it in
# isolation against a single create_clock would report nothing useful.
#=============================================================================
add_ip(
  NAME            clk_gate
  TOP             clk_gate
  SOURCES         rtl/clk_gate.sv
  SVTB            tb/tb_clk_gate.sv
  COCOTB_MODULES  test_clk_gate
  CLOCK_PERIOD_NS 10.0
  CLOCK_PORT      clk
  NO_STA
)
