#============================================================================
# ip/bus - on-chip bus interfaces
#
# apb_slave and axi4_lite_slave drive the same register request port, so
# register logic written once sits behind either bus. axi4_stream_slice
# shapes the timing of a stream without changing its content.
#============================================================================
add_ip_category(bus
  apb_slave
  axi4_lite_slave
  axi4_stream_slice
)
