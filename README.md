# soc-ip-portfolio
A modular SystemVerilog-based SoC IP library including arithmetic units, bus interfaces, DSP blocks, peripherals, and cryptographic cores.
```
soc-ip-portfolio/
│
├── arithmetic/
│ ├── adder.sv
│ ├── multiplier.sv
│ ├── mac.sv
│ └── cordic.sv
│
├── memory/
│ ├── fifo_sync.sv
│ ├── fifo_async.sv
│ ├── register_file.sv
│ └── bram_ctrl.sv
│
├── peripherals/
│ ├── uart.sv
│ ├── spi_master.sv
│ ├── i2c_master.sv
│ └── gpio.sv
│
├── bus/
│ ├── axi4_lite_slave.sv
│ ├── axi4_stream.sv
│ └── apb_slave.sv
│
├── dsp/
│ ├── fir.sv
│ ├── iir.sv
│ ├── fft.sv
│ └── cic.sv
│
├── ml/
│ ├── mac_array.sv
│ ├── pe.sv
│ └── systolic_array.sv
│
└── crypto/
├── aes128.sv
├── sha256.sv
└── lfsr_rng.sv
```
