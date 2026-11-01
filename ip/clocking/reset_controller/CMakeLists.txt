#=============================================================================
# ip/clocking/reset_controller
#=============================================================================
add_ip(
  NAME            reset_controller
  TOP             reset_controller
  SOURCES         rtl/reset_controller.sv
  DEPENDS         cdc_reset_sync
  SVTB            tb/tb_reset_controller.sv
  COCOTB_MODULES  test_reset_controller
  PARAMS          NUM_STAGES=4 STAGE_DELAY=4 MIN_ASSERT_CYCLES=16 SYNC_STAGES=3
  CLOCK_PERIOD_NS 10.0
  CLOCK_PORT      clk
)
