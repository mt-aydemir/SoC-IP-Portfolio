#=============================================================================
# ip/cdc - clock domain crossing primitives
#
# Order is significant: pulse_sync and handshake build on sync_2ff.
#
# The asynchronous FIFO is not listed here. It is a CDC block, but it is also
# a memory, and duplicating it in two categories would mean two copies of the
# same Gray-pointer logic. It is implemented once as ip/memory/fifo_async,
# which DEPENDS on cdc_sync_2ff from this category.
#=============================================================================
add_ip_category(cdc
  sync_2ff
  reset_sync
  pulse_sync
  handshake
)
