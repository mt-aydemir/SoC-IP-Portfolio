# ram_sp

Single-port synchronous RAM with byte enables and an optional output register.

Written as an inferable array with no vendor primitive and no `ram_style`
attribute, so the same source maps onto FPGA block RAM, distributed RAM or an
ASIC macro according to the target tool's own heuristics. Guiding that choice
belongs in the project's constraints, not in the IP.

| | |
|---|---|
| **Category** | `memory` |
| **Top module** | `ram_sp` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | none — see below |
| **Latency** | 1 cycle, or 2 with `OUTPUT_REG` |
| **Verified at** | 5.0 ns clock period |
| **Licence** | Apache-2.0 |

## No reset, deliberately

A reset on a memory array forces every bit into fabric flip-flops: a 1024x32
array becomes 32768 registers instead of one block RAM. Contents are undefined
until written, which is what every real memory does. The block has no `rst_n`
port at all rather than an unused one.

## Read-during-write

Reading and writing the same address in the same cycle returns the **old**
contents. That is the behaviour every target can implement. Write-first is not
universally available and is deliberately not offered as a parameter: an option
that silently changes meaning between targets is worse than no option.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Clock |
| `en` | in | 1 | Access enable |
| `we` | in | 1 | Write when high, read when low |
| `be` | in | `DATA_WIDTH/8` | Byte enables |
| `addr` | in | `$clog2(DEPTH)` | Word address |
| `wdata` | in | `DATA_WIDTH` | Write data |
| `rdata` | out | `DATA_WIDTH` | Read data |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_WIDTH` | `int unsigned` | 32 | >= 8 | Word width; a multiple of 8 with byte enables |
| `DEPTH` | `int unsigned` | 1024 | >= 2 | Words; need not be a power of two |
| `BYTE_ENABLE` | `int unsigned` | 1 | 0 or 1 | Per-byte write masking |
| `OUTPUT_REG` | `int unsigned` | 0 | 0 or 1 | Registered output stage |
| `INIT_FILE` | `string` | `""` | — | `$readmemh` file, simulation only |

`OUTPUT_REG` costs a cycle and buys timing closure. On an FPGA it maps into the
block RAM's own output register and costs no fabric at all.

## Quick start

```systemverilog
ram_sp #(
  .DATA_WIDTH  (32),
  .DEPTH       (4096),
  .BYTE_ENABLE (1),
  .OUTPUT_REG  (1)
) u_mem (
  .clk   (clk),
  .en    (mem_en),
  .we    (mem_we),
  .be    (mem_be),
  .addr  (mem_addr),
  .wdata (mem_wdata),
  .rdata (mem_rdata)
);
```

## Verification

```bash
ctest --test-dir build -R 'ram_sp'
```

- `cocotb/test_ram_sp.py` — write and read back, byte-enable masking,
  read-during-write, the enable holding the output, randomised traffic against
  a dictionary model, a full sweep, and the address boundaries. Run at three
  parameter configurations.
- `tb/tb_ram_sp.sv` — portable self-checking smoke test.

Full documentation: [`docs/index.rst`](docs/index.rst).
