#=============================================================================
# ip/memory/register_file
#=============================================================================
add_ip(
  NAME            register_file
  TOP             register_file
  SOURCES         rtl/register_file.sv
  SVTB            tb/tb_register_file.sv
  COCOTB_MODULES  test_register_file
  PARAMS          DATA_WIDTH=32 NUM_REGS=32 NUM_READ_PORTS=2
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
)
