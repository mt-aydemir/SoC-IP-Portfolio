#=============================================================================
# ip/arithmetic/mac
#
# Depends on multiplier and accumulator: the block is those two plus the clear
# alignment between them, which is the part that is easy to get wrong and the
# reason it exists as an IP rather than as two instantiations per caller.
#
# ACC_WIDTH is 40 for a 16x16 product: 32 bits for the product and 8 of growth,
# which is the honest width for a frame of up to 256 terms.
#=============================================================================
add_ip(
  NAME            mac
  TOP             mac
  SOURCES         rtl/mac.sv
  DEPENDS         multiplier accumulator
  SVTB            tb/tb_mac.sv
  COCOTB_MODULES  test_mac
  PARAMS          A_WIDTH=16 B_WIDTH=16 ACC_WIDTH=40 SIGNED=1 SATURATE=0
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
  STA_SDC         scripts/mac.sdc
)
