#=============================================================================
# ip/memory/fifo_async
#
# NO_STA: two asynchronous clock domains. The pointer crossings are
# constrained by scripts/fifo_async.sdc at integration time.
#=============================================================================
add_ip(
  NAME            fifo_async
  TOP             fifo_async
  SOURCES         rtl/fifo_async.sv
  DEPENDS         ram_sdp cdc_sync_2ff
  SVTB            tb/tb_fifo_async.sv
  COCOTB_MODULES  test_fifo_async
  PARAMS          DATA_WIDTH=32 DEPTH=16 SYNC_STAGES=2
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      wr_clk
  NO_STA
)
