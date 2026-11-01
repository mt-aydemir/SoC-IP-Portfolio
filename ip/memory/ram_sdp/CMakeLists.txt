#=============================================================================
# ip/memory/ram_sdp
#
# NO_STA: two independent clock inputs. The single-clock constraint set that
# run_sta.py applies cannot describe the block; the integrating project times
# each port against its own clock.
#=============================================================================
add_ip(
  NAME            ram_sdp
  TOP             ram_sdp
  SOURCES         rtl/ram_sdp.sv
  SVTB            tb/tb_ram_sdp.sv
  COCOTB_MODULES  test_ram_sdp
  PARAMS          DATA_WIDTH=32 DEPTH=256 BYTE_ENABLE=0 OUTPUT_REG=0
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      wr_clk
  NO_STA
)
