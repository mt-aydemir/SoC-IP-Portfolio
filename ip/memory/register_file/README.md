# register_file

Multi-port register file: one synchronous write port and a configurable number
of asynchronous read ports.

Reads are combinational so an instruction can fetch its operands and use them
in the same cycle. That is what makes it a register file rather than a RAM —
and also what makes it expensive: the storage infers as flip-flops with one
multiplexer per read port, not as a memory macro. For anything larger than a
few dozen entries, or where a cycle of read latency is acceptable, `ram_sp` or
`ram_sdp` is the right block.

| | |
|---|---|
| **Category** | `memory` |
| **Top module** | `register_file` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, clears every register |
| **Latency** | reads combinational; writes visible next cycle |
| **Verified at** | 5.0 ns clock period |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Clock |
| `rst_n` | in | 1 | Active-low reset |
| `write_en` | in | 1 | Write enable |
| `write_addr` | in | `$clog2(NUM_REGS)` | Write address |
| `write_data` | in | `DATA_WIDTH` | Write data |
| `read_addr` | in | `NUM_READ_PORTS x $clog2(NUM_REGS)` | Packed read addresses |
| `read_data` | out | `NUM_READ_PORTS x DATA_WIDTH` | Packed read data |

The read ports are packed arrays so the port count is a parameter rather than
a fixed set of signals.

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_WIDTH` | `int unsigned` | 32 | >= 1 | Width of each register |
| `NUM_REGS` | `int unsigned` | 32 | >= 2 | Number of registers; need not be a power of two |
| `NUM_READ_PORTS` | `int unsigned` | 2 | >= 1 | Independent asynchronous read ports |
| `ZERO_REGISTER` | `int unsigned` | 1 | 0 or 1 | Hardwire register 0 to zero and ignore writes to it |
| `BYPASS_WRITE` | `int unsigned` | 1 | 0 or 1 | Read-during-write returns the new data |

`ZERO_REGISTER` follows the RISC-V and MIPS convention. `BYPASS_WRITE` is
normally wanted: without it the datapath needs its own forwarding path for the
write-back stage.

## Quick start

```systemverilog
register_file #(
  .DATA_WIDTH     (32),
  .NUM_REGS       (32),
  .NUM_READ_PORTS (2)
) u_regfile (
  .clk        (clk),
  .rst_n      (rst_n),
  .write_en   (wb_valid),
  .write_addr (wb_rd),
  .write_data (wb_data),
  .read_addr  ({id_rs2, id_rs1}),
  .read_data  ({rs2_value, rs1_value})
);
```

## Verification

```bash
ctest --test-dir build -R 'register_file'
```

- `cocotb/test_register_file.py` — reset state, write then read, register zero,
  the read-during-write bypass, read-port independence, 1500 cycles of
  randomised traffic against a dictionary model, and a sweep proving every
  register holds its own value.
- `tb/tb_register_file.sv` — portable self-checking smoke test.

Full documentation: [`docs/index.rst`](docs/index.rst).
