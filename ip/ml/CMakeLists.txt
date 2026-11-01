#=============================================================================
# ip/ml - machine learning inference blocks
#
# Order is significant. The processing element is the leaf; the array is built
# from it; the accelerator top wires the array to the requantiser and to two
# blocks from the memory category, which is registered before this one.
#=============================================================================
add_ip_category(ml
  systolic_pe
  requant_int8
  systolic_array
  mac_array
  cnn_accel
)
