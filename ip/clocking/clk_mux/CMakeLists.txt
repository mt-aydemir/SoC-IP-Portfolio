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
)
