#=============================================================================
# ip/peripherals/spi_master
#
# Mode and bit order are run-time inputs, so one build covers all four modes;
# the SystemVerilog testbench runs a 12-bit word as a second geometry.
#=============================================================================
add_ip(
  NAME            spi_master
  TOP             spi_master
  SOURCES         rtl/spi_master.sv
  SVTB            tb/tb_spi_master.sv
  COCOTB_MODULES  test_spi_master
  PARAMS          DATA_WIDTH=8 DIV_WIDTH=8
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
)
