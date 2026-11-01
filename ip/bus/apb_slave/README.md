# apb_slave

AMBA APB4 completer that bridges APB transfers onto a simple register request
port.

Each APB transfer becomes exactly one request on the register port, and that
request's response becomes the transfer's `PRDATA` and `PSLVERR`. The register
logic behind it never sees APB. `axi4_lite_slave` drives the same register
port, so register logic written once can sit behind either bus.

| | |
|---|---|
| **Category** | `bus` |
| **Top module** | `apb_slave` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | `REGISTERED=0`: none; `REGISTERED=1`: one wait state |
| **Verified at** | `ADDR_WIDTH=12 DATA_WIDTH=32 REGISTERED=1`, 5.0 ns; both modes in the SV testbench |
| **Licence** | Apache-2.0 |

## Register port

| Signal | Dir | Width | Description |
|---|---|---|---|
| `reg_valid` / `reg_ready` | out / in | 1 | Request handshake; held until taken |
| `reg_write` | out | 1 | 1 = write |
| `reg_addr` | out | `ADDR_WIDTH` | Byte address (`PADDR`) |
| `reg_wdata`, `reg_strb` | out | `DATA_WIDTH`, `DATA_WIDTH/8` | `PWDATA`, `PSTRB` |
| `reg_prot` | out | 3 | `PPROT` |
| `reg_rdata`, `reg_error` | in | `DATA_WIDTH`, 1 | Response, sampled on the accepting edge |

A block with a combinational read, such as `gpio`, connects with `reg_ready`
tied high:

```systemverilog
assign gpio_wr_en = reg_valid && reg_write;
assign gpio_addr  = reg_addr[4:2];
assign reg_rdata  = gpio_rd_data;
assign reg_ready  = 1'b1;
assign reg_error  = 1'b0;
```

## APB side

`psel`, `penable`, `pwrite`, `paddr`, `pwdata`, `pstrb`, `pprot` in;
`pready`, `prdata`, `pslverr` out. These are the APB4 signals, without the
`P` prefix capitalisation.

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | 12 | 2 to 32 | `PADDR` width |
| `DATA_WIDTH` | `int unsigned` | 32 | 8, 16, 32 | `PRDATA` / `PWDATA` width |
| `REGISTERED` | `int unsigned` | 1 | 0, 1 | 0: combinational response, zero wait states; 1: registered response, one wait state |

## Quick start

```bash
ctest --test-dir build -R 'apb_slave'
```

Documentation: [`docs/index.rst`](docs/index.rst).
