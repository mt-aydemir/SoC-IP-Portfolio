#=============================================================================
# ip/memory/ram_sp
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
  NAME            ram_sp
  TOP             ram_sp
  SOURCES         rtl/ram_sp.sv
  SVTB            tb/tb_ram_sp.sv
  COCOTB_MODULES  test_ram_sp
  PARAMS          DATA_WIDTH=32 DEPTH=256 BYTE_ENABLE=1 OUTPUT_REG=0
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
  NO_STA
)
