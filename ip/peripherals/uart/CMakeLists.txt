#=============================================================================
# ip/peripherals/uart
#
# Simulated with even parity so the parity paths are exercised; the
# SystemVerilog testbench covers a second geometry (7 data bits, odd parity,
# two stop bits).
#=============================================================================
add_ip(
  NAME            uart
  TOP             uart
  SOURCES         rtl/uart.sv
  DEPENDS         cdc_sync_2ff
  SVTB            tb/tb_uart.sv
  COCOTB_MODULES  test_uart
  PARAMS          DATA_BITS=8 PARITY=1 STOP_BITS=1 DIV_WIDTH=16 SYNC_STAGES=2
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
)
