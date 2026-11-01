#=============================================================================
# ip/memory/bram_ctrl
#
# NO_STA: in the portfolio's vendor-independent flow the storage array is
# built from flip-flops on a generic library that has one drive strength per
# cell, so the address decode ends up as single minimum-size gates driving
# thousands of loads with nothing to buffer them. OpenSTA then reports a
# negative slack of several nanoseconds that describes the library, not the
# design. In any real implementation the array is a RAM macro or an FPGA block
# RAM with its own timing model, and is timed in the integrating project
# against that model.
#=============================================================================
add_ip(
  NAME            bram_ctrl
  TOP             bram_ctrl
  SOURCES         rtl/bram_ctrl.sv
  DEPENDS         ram_sp
  SVTB            tb/tb_bram_ctrl.sv
  COCOTB_MODULES  test_bram_ctrl
  PARAMS          DATA_WIDTH=32 DEPTH=256 WRITE_RESPONSE=1
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
  NO_STA
)
