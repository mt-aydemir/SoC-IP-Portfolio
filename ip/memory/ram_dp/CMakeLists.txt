#=============================================================================
# ip/memory/ram_dp
#
# LINT_ARGS -Wno-MULTIDRIVEN: a true dual-port memory is written from two
# clocked processes, one per port. That is the structure every synthesiser
# recognises as a dual-port macro and it cannot be expressed any other way with
# independent clocks. Verilator correctly observes that the array has two
# driving blocks; the resulting collision rules are documented in the block
# header and are the integrator responsibility, exactly as for the physical
# macro. This is the only lint exception in the portfolio.
#
# NO_STA: two independent clock inputs, as for ram_sdp.
#=============================================================================
add_ip(
  NAME            ram_dp
  TOP             ram_dp
  SOURCES         rtl/ram_dp.sv
  SVTB            tb/tb_ram_dp.sv
  COCOTB_MODULES  test_ram_dp
  PARAMS          DATA_WIDTH=32 DEPTH=256 BYTE_ENABLE=1 OUTPUT_REG=0
  LINT_ARGS       -Wno-MULTIDRIVEN
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk_a
  NO_STA
)
