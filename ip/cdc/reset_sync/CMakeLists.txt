#=============================================================================
# ip/cdc/reset_sync
#
# NO_STA: the block has no data path to time. Its only timing requirement is
# the recovery/removal check on the reset release, which is meaningless
# without the surrounding design's clock definition.
#=============================================================================
add_ip(
  NAME            cdc_reset_sync
  TOP             cdc_reset_sync
  SOURCES         rtl/cdc_reset_sync.sv
  SVTB            tb/tb_cdc_reset_sync.sv
  COCOTB_MODULES  test_cdc_reset_sync
  PARAMS          STAGES=3
  CLOCK_PERIOD_NS 10.0
  CLOCK_PORT      clk
  NO_STA
  STA_SDC         scripts/cdc_reset_sync.sdc
  SDC_INST_VAR    RST_SYNC_INST
  FORMAL_MULTICLOCK
  FORMAL_TOP      cdc_reset_sync_formal
  FORMAL_SOURCES  formal/cdc_reset_sync_formal.sv
  FORMAL_DEPTH    16
)
