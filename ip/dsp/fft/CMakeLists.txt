#=============================================================================
# ip/dsp/fft
#
# A single add_ip() call registers the complete flow:
#   lint -> cocotb simulation + SystemVerilog testbench -> synthesis -> timing
#=============================================================================
add_ip(
  NAME            fft
  TOP             fft
  SOURCES         rtl/fft_twiddle.sv rtl/fft.sv
  SVTB            tb/tb_fft.sv
  COCOTB_MODULES  test_fft
  PARAMS          N_LOG2=5 DATA_WIDTH=12
  CLOCK_PERIOD_NS 10.0
  CLOCK_PORT      clk
  STA_SDC         scripts/fft.sdc
)
