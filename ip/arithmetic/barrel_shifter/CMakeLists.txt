#=============================================================================
# ip/arithmetic/barrel_shifter
#
# Verified at a power-of-two width, which is the configuration in which every
# representable shift amount is in range. The suites adapt to a
# non-power-of-two width and restrict the rotate properties accordingly.
#=============================================================================
add_ip(
  NAME            barrel_shifter
  TOP             barrel_shifter
  SOURCES         rtl/barrel_shifter.sv
  SVTB            tb/tb_barrel_shifter.sv
  COCOTB_MODULES  test_barrel_shifter
  PARAMS          WIDTH=32
  NO_STA
)
