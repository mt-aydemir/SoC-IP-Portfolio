#=============================================================================
# ip/peripherals/gpio
#=============================================================================
add_ip(
  NAME            gpio
  TOP             gpio
  SOURCES         rtl/gpio.sv
  DEPENDS         cdc_sync_2ff
  SVTB            tb/tb_gpio.sv
  COCOTB_MODULES  test_gpio
  PARAMS          WIDTH=8 SYNC_STAGES=2
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
)
