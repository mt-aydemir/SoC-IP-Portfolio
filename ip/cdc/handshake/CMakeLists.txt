#=============================================================================
# ip/cdc/handshake
#
# NO_STA: see pulse_sync. Two asynchronous clocks, constrained by
# scripts/cdc_handshake.sdc at integration time.
#=============================================================================
add_ip(
  NAME            cdc_handshake
  TOP             cdc_handshake
  SOURCES         rtl/cdc_handshake.sv
  DEPENDS         cdc_sync_2ff
  SVTB            tb/tb_cdc_handshake.sv
  COCOTB_MODULES  test_cdc_handshake
  PARAMS          DATA_WIDTH=32 STAGES=2
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      src_clk
  NO_STA
)
