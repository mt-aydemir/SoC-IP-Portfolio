#=============================================================================
# ip/peripherals - processor-facing I/O controllers
#
# Every external input is asynchronous to the core clock and passes through
# cdc_sync_2ff before any logic sees it, so this category depends on cdc.
#=============================================================================
add_ip_category(peripherals
  gpio
  uart
  spi_master
  i2c_master
)
