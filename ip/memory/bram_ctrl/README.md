# bram_ctrl

Block RAM controller. Presents a pipelined request/response interface in front
of a single-port synchronous memory.

A synchronous RAM is not directly usable behind a bus. It has fixed read
latency, it cannot be stalled once a read is issued, and it has no notion of
back-pressure: the data appears when it appears, whether or not anyone is ready
for it. A bus expects flow control in both directions and a response for every
request. This block bridges the two.

| | |
|---|---|
| **Category** | `memory` |
| **Top module** | `bram_ctrl` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | 2 cycles from accepted read to response |
| **Throughput** | one request per cycle sustained |
| **Depends on** | `ram_sp` |
| **Licence** | Apache-2.0 |

## Flow control

A request is accepted only if the response buffer will have room for its result
on arrival — counting the result already in flight from the previous cycle.
Once a read has been issued to the RAM it cannot be recalled, so the room must
be reserved *before* the request is accepted, not after.

The buffer is two entries deep for the same reason `fifo_sync`'s output stage
is: one entry would force the controller to idle whenever the consumer stalled
for a single cycle, halving throughput on a bus that back-pressures at all.

## Responses

Every accepted request produces exactly one response, in order, writes
included. A write response carries no data and exists so the interface is
uniform: a bridge in front of this block can map requests and responses one to
one without tracking which were writes. Set `WRITE_RESPONSE` to 0 for a
fire-and-forget write port.

An address outside the array is answered with `rsp_err` and never reaches the
memory. Silently aliasing a bad address onto a good one turns a software bug
into corrupted data somewhere unrelated.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` / `rst_n` | in | 1 | Clock and active-low reset |
| `req_valid` / `req_ready` | — | 1 | Request handshake |
| `req_we` | in | 1 | Write when high |
| `req_addr` | in | `$clog2(DEPTH)` | Word address |
| `req_be` | in | `DATA_WIDTH/8` | Byte enables |
| `req_wdata` | in | `DATA_WIDTH` | Write data |
| `rsp_valid` / `rsp_ready` | — | 1 | Response handshake |
| `rsp_rdata` | out | `DATA_WIDTH` | Read data |
| `rsp_err` | out | 1 | Address was out of range |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_WIDTH` | `int unsigned` | 32 | multiple of 8, >= 8 | Word width |
| `DEPTH` | `int unsigned` | 1024 | >= 2 | Words; need not be a power of two |
| `WRITE_RESPONSE` | `int unsigned` | 1 | 0 or 1 | Answer writes as well as reads |
| `INIT_FILE` | `string` | `""` | — | `$readmemh` file, simulation only |

## Quick start

```systemverilog
bram_ctrl #(
  .DATA_WIDTH (32),
  .DEPTH      (8192)
) u_bram (
  .clk (clk), .rst_n (rst_n),
  .req_valid (mem_req_valid), .req_ready (mem_req_ready),
  .req_we    (mem_req_we),    .req_addr  (mem_req_addr),
  .req_be    (mem_req_be),    .req_wdata (mem_req_wdata),
  .rsp_valid (mem_rsp_valid), .rsp_ready (mem_rsp_ready),
  .rsp_rdata (mem_rsp_rdata), .rsp_err   (mem_rsp_err)
);
```

## Verification

```bash
ctest --test-dir build -R 'bram_ctrl'
```

- `cocotb/test_bram_ctrl.py` — reset state, write then read, byte-enable
  masking, responses held under back-pressure, out-of-range error reporting,
  randomised traffic with response back-pressure, sustained streaming, and a
  mid-stream reset. Run at three parameter configurations.
- `tb/tb_bram_ctrl.sv` — portable self-checking smoke test.

Full documentation: [`docs/index.rst`](docs/index.rst).
