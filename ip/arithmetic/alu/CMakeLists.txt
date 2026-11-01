#=============================================================================
# ip/arithmetic/alu
#
# Depends on adder and barrel_shifter: there is one implementation of two's
# complement addition with overflow detection in the portfolio, and one
# shifter, and the alu reuses both rather than growing its own.
#=============================================================================
add_ip(
  NAME            alu
  TOP             alu
  SOURCES         rtl/alu.sv
  DEPENDS         adder barrel_shifter
  SVTB            tb/tb_alu.sv
  COCOTB_MODULES  test_alu
  PARAMS          WIDTH=32
  NO_STA
  FORMAL_TOP      alu_formal
  FORMAL_SOURCES  formal/alu_formal.sv
  FORMAL_DEPTH    2
)
