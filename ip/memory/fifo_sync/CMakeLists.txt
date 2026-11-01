#=============================================================================
# ip/memory/fifo_sync
#=============================================================================
add_ip(
  NAME            fifo_sync
  TOP             fifo_sync
  SOURCES         rtl/fifo_sync.sv
  DEPENDS         ram_sdp
  SVTB            tb/tb_fifo_sync.sv
  COCOTB_MODULES  test_fifo_sync
  PARAMS          DATA_WIDTH=32 DEPTH=16
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
  STA_SDC         scripts/fifo_sync.sdc
  SDC_INST_VAR    FIFO_INST
  FORMAL_TOP      fifo_sync_formal
  FORMAL_DEPTH    10
  FORMAL_SOURCES  formal/fifo_sync_formal.sv
)
