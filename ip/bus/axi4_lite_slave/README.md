# axi4_lite_slave

AMBA AXI4-Lite subordinate that bridges reads and writes onto a simple register
request port.

The five AXI channels are handled independently, as the protocol requires: a
write's address and data may arrive in either order or together, and reads do
not wait for writes. Every write becomes one register request and one B
response; every read one request and one R response. The register port is the
same as `apb_slave`'s, so register logic written once sits behind either bus.

| | |
|---|---|
| **Category** | `bus` |
| **Top module** | `axi4_lite_slave` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Outstanding** | one write and one read |
| **Throughput** | one transfer every two cycles per direction, plus wait states |
| **Responses** | OKAY, or SLVERR from `reg_error` |
| **Verified at** | `ADDR_WIDTH=12 DATA_WIDTH=32`, 5.0 ns |
| **Licence** | Apache-2.0 |

## Structure

- AW, W and AR each have a one-entry holding register; a channel is ready
  whenever its register is empty.
- A write issues once AW and W are both held and no B is outstanding; a read
  once AR is held and no R is outstanding. Writes go first when both are
  ready; the choice is locked while the request waits.
- Neither direction starves: a direction just served cannot be ready in the
  next cycle, so the other gets the slot.
- B and R are registered, and every output is a flip-flop or a function of
  flip-flops only.

## Interface

| Signal | Dir | Description |
|---|---|---|
| `s_axi_aw*` | in / `awready` out | `awvalid`, `awaddr`, `awprot` |
| `s_axi_w*` | in / `wready` out | `wvalid`, `wdata`, `wstrb` |
| `s_axi_b*` | out / `bready` in | `bvalid`, `bresp` |
| `s_axi_ar*` | in / `arready` out | `arvalid`, `araddr`, `arprot` |
| `s_axi_r*` | out / `rready` in | `rvalid`, `rdata`, `rresp` |
| `reg_valid` / `reg_ready` | out / in | Request handshake; held until taken |
| `reg_write`, `reg_addr`, `reg_wdata`, `reg_strb`, `reg_prot` | out | The request; data and strobes zero on reads |
| `reg_rdata`, `reg_error` | in | Response, sampled on the accepting edge |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `ADDR_WIDTH` | `int unsigned` | 12 | 2 to 64 | Address width |
| `DATA_WIDTH` | `int unsigned` | 32 | 32, 64 | Data width, as AXI4-Lite allows |

## Quick start

```bash
ctest --test-dir build -R 'axi4_lite_slave'
```

Documentation: [`docs/index.rst`](docs/index.rst).
