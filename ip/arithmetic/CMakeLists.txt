#=============================================================================
# ip/arithmetic - datapath primitives
#
# Order is significant: an IP may only depend on an IP registered before it.
#
#   adder           is the carry chain the subtractor and the alu reuse
#   barrel_shifter  is the shifter the alu reuses
#   multiplier      and accumulator are the two halves of the mac
#=============================================================================
add_ip_category(arithmetic
  adder
  subtractor
  comparator
  barrel_shifter
  multiplier
  accumulator
  mac
  alu
  divider
  cordic
)
