#=============================================================================
# ip/memory - storage primitives
#
# Order is significant. ram_sdp is the storage behind both FIFOs, and
# fifo_async additionally depends on cdc_sync_2ff from the cdc category, which
# is registered before this one.
#=============================================================================
add_ip_category(memory
  register_file
  ram_sp
  ram_sdp
  ram_dp
  fifo_sync
  fifo_async
  bram_ctrl
)
