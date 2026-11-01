#=============================================================================
# ip/cdc/sync_2ff
#=============================================================================
add_ip(
  NAME            cdc_sync_2ff
  TOP             cdc_sync_2ff
  SOURCES         rtl/cdc_sync_2ff.sv
  SVTB            tb/tb_cdc_sync_2ff.sv
  COCOTB_MODULES  test_cdc_sync_2ff
  PARAMS          WIDTH=8 STAGES=3
  CLOCK_PERIOD_NS 4.0
  CLOCK_PORT      clk
)
