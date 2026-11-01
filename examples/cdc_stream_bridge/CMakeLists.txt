#=============================================================================
# examples/cdc_stream_bridge - a stream crossing between unrelated clocks
#
# Two clocks, so no single-clock timing analysis applies: the crossing is
# safe by construction (Gray-coded pointers through synchronisers), and its
# constraints are the false-path declarations in fifo_async's own SDC.
#=============================================================================
add_ip(
  NAME            cdc_stream_bridge
  TOP             cdc_stream_bridge
  SOURCES         rtl/cdc_stream_bridge.sv
  DEPENDS         cdc_reset_sync fifo_async
  COCOTB_MODULES  test_cdc_stream_bridge
  PARAMS          DATA_WIDTH=32 DEPTH=16 SYNC_STAGES=2
  CLOCK_PORT      src_clk
  NO_STA
)
