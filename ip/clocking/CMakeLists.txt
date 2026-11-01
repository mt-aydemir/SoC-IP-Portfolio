#=============================================================================
# ip/clocking - clock generation, gating and distribution
#
# Order is significant: reset_controller builds on cdc_reset_sync, which is
# registered by the cdc category before this one.
#=============================================================================
add_ip_category(clocking
  clk_divider
  clk_gate
  clk_mux
  reset_controller
)
