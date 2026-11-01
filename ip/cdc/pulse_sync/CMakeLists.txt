#=============================================================================
# ip/cdc/pulse_sync
#
# NO_STA: a two-clock design cannot be timed against the single-clock
# constraint set that run_sta.py applies. The crossings are constrained by
# scripts/cdc_pulse_sync.sdc in the integrating project instead.
#=============================================================================
add_ip(
  NAME            cdc_pulse_sync
  TOP             cdc_pulse_sync
  SOURCES         rtl/cdc_pulse_sync.sv
  DEPENDS         cdc_sync_2ff
  SVTB            tb/tb_cdc_pulse_sync.sv
  COCOTB_MODULES  test_cdc_pulse_sync
  PARAMS          STAGES=2
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      src_clk
  NO_STA
)
