#=============================================================================
# ip/peripherals/i2c_master
#=============================================================================
add_ip(
  NAME            i2c_master
  TOP             i2c_master
  SOURCES         rtl/i2c_master.sv
  DEPENDS         cdc_sync_2ff
  SVTB            tb/tb_i2c_master.sv
  COCOTB_MODULES  test_i2c_master
  PARAMS          DIV_WIDTH=16 SYNC_STAGES=2
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
)
