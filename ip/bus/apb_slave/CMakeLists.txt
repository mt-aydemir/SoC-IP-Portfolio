#=============================================================================
# ip/bus/apb_slave
#
# A single add_ip() call registers the complete flow:
#   lint -> cocotb simulation + SystemVerilog testbench -> synthesis -> timing
#=============================================================================
add_ip(
  NAME            apb_slave
  TOP             apb_slave
  SOURCES         rtl/apb_slave.sv
  SVTB            tb/tb_apb_slave.sv
  COCOTB_MODULES  test_apb_slave
  PARAMS          ADDR_WIDTH=12 DATA_WIDTH=32 REGISTERED=1
  CLOCK_PERIOD_NS 5.0
  CLOCK_PORT      clk
  STA_SDC         scripts/apb_slave.sdc
  FORMAL_TOP      apb_slave_formal
  FORMAL_SOURCES  formal/apb_slave_formal.sv
  FORMAL_DEPTH    10
  UVM_TOP         tb_apb_slave_uvm
  UVM_SOURCES     uvm/apb_slave_if.sv uvm/apb_slave_uvm_pkg.sv uvm/tb_apb_slave_uvm.sv
  UVM_TESTS       apb_random_test apb_back_to_back_test
  UVM_CONFIGS     REGISTERED=1 REGISTERED=0
)
