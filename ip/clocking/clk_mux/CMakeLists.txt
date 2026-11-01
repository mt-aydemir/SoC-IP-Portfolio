#=============================================================================
# ip/clocking/clk_mux
#
# NO_STA: two asynchronous clock inputs and a generated clock output. The
# single-clock constraint set that run_sta.py applies cannot describe this
# block; scripts/clk_mux.sdc does, at integration time.
#=============================================================================
add_ip(
  NAME            clk_mux
  TOP             clk_mux
  SOURCES         rtl/clk_mux.sv
  SVTB            tb/tb_clk_mux.sv
  COCOTB_MODULES  test_clk_mux
  PARAMS          STAGES=2
  CLOCK_PERIOD_NS 10.0
  CLOCK_PORT      clk0
  NO_STA
  STA_SDC         scripts/clk_mux.sdc
  SDC_INST_VAR    MUX_INST
  SDC_VARS        "MUX_CLK0=[get_clocks clk0]" "MUX_CLK1=[get_clocks clk1]"
  SDC_CLOCKS      clk1
  FORMAL_MULTICLOCK
  FORMAL_TOP      clk_mux_formal
  FORMAL_SOURCES  formal/clk_mux_formal.sv
  FORMAL_DEPTH    30
)
