# ram_sdp

Simple dual-port synchronous RAM: one write port and one read port, each in its
own clock domain.

This is the most useful memory configuration in practice and the cheapest
dual-port structure a target can provide. Every FPGA block RAM supports it
natively, and on an ASIC it maps to a 1R1W macro substantially smaller than a
true dual-port one.

It is also the only dual-port arrangement with a **single driving process** for
the array. A true dual-port memory is written from two processes and is
therefore multiply driven, with all the collision rules that implies. Here the
read port only reads, so there is nothing to collide.

| | |
|---|---|
| **Category** | `memory` |
| **Top module** | `ram_sdp` |
| **Clock domains** | 2 (`wr_clk`, `rd_clk`), may be the same |
| **Reset** | none — see `ram_sp` |
| **Latency** | 1 read cycle, or 2 with `OUTPUT_REG` |
| **Used by** | `fifo_sync`, `fifo_async` |
| **Licence** | Apache-2.0 |

## Collision rules

| Access | Result |
|---|---|
| Write and read, different addresses | Always safe |
| Write and read, same address | The read returns **old** data |

The second holds regardless of clock relationship: the read is issued from the
array before the write in that cycle has landed. Callers needing the new data
must bypass around the memory, which is exactly what `fifo_sync` does for its
first-word-fall-through path.

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `wr_clk` | in | 1 | Write clock |
| `wr_en` | in | 1 | Write enable |
| `wr_be` | in | `DATA_WIDTH/8` | Byte enables |
| `wr_addr` | in | `$clog2(DEPTH)` | Write address |
| `wr_data` | in | `DATA_WIDTH` | Write data |
| `rd_clk` | in | 1 | Read clock |
| `rd_en` | in | 1 | Read enable |
| `rd_addr` | in | `$clog2(DEPTH)` | Read address |
| `rd_data` | out | `DATA_WIDTH` | Read data |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_WIDTH` | `int unsigned` | 32 | >= 1 | Word width |
| `DEPTH` | `int unsigned` | 1024 | >= 2 | Words; need not be a power of two |
| `BYTE_ENABLE` | `int unsigned` | 0 | 0 or 1 | Per-byte write masking |
| `OUTPUT_REG` | `int unsigned` | 0 | 0 or 1 | Registered read output |
| `INIT_FILE` | `string` | `""` | — | `$readmemh` file, simulation only |

## Quick start

```systemverilog
ram_sdp #(
  .DATA_WIDTH (16),
  .DEPTH      (2048)
) u_line_buffer (
  .wr_clk  (clk_capture),
  .wr_en   (pixel_valid),
  .wr_be   ('1),
  .wr_addr (write_index),
  .wr_data (pixel),
  .rd_clk  (clk_process),
  .rd_en   (1'b1),
  .rd_addr (read_index),
  .rd_data (pixel_out)
);
```

Note that this block provides no synchronisation between the domains. Whatever
tells the reader a word is ready must handle that; `fifo_async` is exactly that
logic, which is why it is built on this memory.

## Verification

```bash
ctest --test-dir build -R 'ram_sdp'
```

- `cocotb/test_ram_sdp.py` — write and read back, byte-enable masking,
  concurrent access to different addresses, same-address collision returning
  old data, randomised traffic at three clock ratios, a full sweep, and
  sustained concurrent traffic.
- `tb/tb_ram_sdp.sv` — portable smoke test at a 10 ns / 17 ns clock ratio.

Full documentation: [`docs/index.rst`](docs/index.rst).
