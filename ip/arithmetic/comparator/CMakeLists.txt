#=============================================================================
# ip/arithmetic/comparator
#
# Verified signed: it is the interpretation in which the ordering outputs are
# non-trivial. The reference models follow the parameter, so the same suites
# verify the unsigned ordering when SIGNED is 0.
#=============================================================================
add_ip(
  NAME            comparator
  TOP             comparator
  SOURCES         rtl/comparator.sv
  SVTB            tb/tb_comparator.sv
  COCOTB_MODULES  test_comparator
  PARAMS          WIDTH=16 SIGNED=1
  NO_STA
  FORMAL_TOP      comparator_formal
  FORMAL_SOURCES  formal/comparator_formal.sv
  FORMAL_DEPTH    2
)
