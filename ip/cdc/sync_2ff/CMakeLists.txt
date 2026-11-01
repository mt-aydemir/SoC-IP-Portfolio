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
  STA_SDC         scripts/cdc_sync_2ff.sdc
  SDC_INST_VAR    SYNC_INST
  SDC_VARS        "SYNC_DST=[get_clocks clk]"
  FORMAL_MULTICLOCK
  FORMAL_TOP      cdc_sync_2ff_formal
  FORMAL_SOURCES  formal/cdc_sync_2ff_formal.sv
  FORMAL_DEPTH    16
)
