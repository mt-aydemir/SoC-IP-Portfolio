# ram_dp

True dual-port synchronous RAM. Both ports can read and write, each in its own
clock domain.

| | |
|---|---|
| **Category** | `memory` |
| **Top module** | `ram_dp` |
| **Clock domains** | 2 (`clk_a`, `clk_b`), may be the same |
| **Reset** | none — see `ram_sp` |
| **Latency** | 1 cycle, or 2 with `OUTPUT_REG` |
| **Licence** | Apache-2.0 |

## Collision behaviour — read this first

The block does **not** arbitrate between the ports. Physical dual-port memories
do not either, and pretending otherwise in RTL would produce a design that
simulates differently from the hardware it becomes.

| Access | Result |
|---|---|
| Read / read, any addresses | Always safe |
| Read / write, different addresses | Always safe |
| Read / write, same address | Old data if the edges are far apart; **undefined** if they coincide |
| Write / write, same address | **Undefined** contents afterwards |

"Coincide" means within the memory's own write-through window, a physical
property of the macro that is not modelled here. Treat any same-address access
from both ports in the same cycle as undefined.

The usual ways to satisfy these rules:

- **partition the address space** — one port owns even addresses, or each owns
  half the array;
- **arbitrate outside the block**, so only one port is enabled at a time;
- **use `fifo_async`** for a producer and consumer sharing data across clock
  domains: it is this memory plus the pointer logic that makes the sharing
  provably safe.

If none of those apply, the design is relying on undefined behaviour.

If only one side ever writes, use `ram_sdp` instead — it is smaller on every
target and has no collision rules beyond read-first.

## Interface

Port A and port B are identical. For `x` in `{a, b}`:

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk_x` | in | 1 | Port clock |
| `en_x` | in | 1 | Access enable |
| `we_x` | in | 1 | Write when high |
| `be_x` | in | `DATA_WIDTH/8` | Byte enables |
| `addr_x` | in | `$clog2(DEPTH)` | Word address |
| `wdata_x` | in | `DATA_WIDTH` | Write data |
| `rdata_x` | out | `DATA_WIDTH` | Read data |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_WIDTH` | `int unsigned` | 32 | >= 8 | Word width |
| `DEPTH` | `int unsigned` | 1024 | >= 2 | Words; need not be a power of two |
| `BYTE_ENABLE` | `int unsigned` | 1 | 0 or 1 | Per-byte write masking |
| `OUTPUT_REG` | `int unsigned` | 0 | 0 or 1 | Registered outputs on both ports |
| `INIT_FILE` | `string` | `""` | — | `$readmemh` file, simulation only |

## Lint exception

This is the only IP in the portfolio with a lint exception. Its
`CMakeLists.txt` declares `LINT_ARGS -Wno-MULTIDRIVEN`, because a true
dual-port memory is written from two clocked processes by necessity and no
other formulation exists with independent clocks. The exception is in the build
file rather than as an in-source pragma so that it stays visible and auditable:
`grep LINT_ARGS ip/` lists every exception in the repository.

## Verification

```bash
ctest --test-dir build -R 'ram_dp'
```

- `cocotb/test_ram_dp.py` — each port reading its own writes, cross-port
  visibility, byte-enable masking on both ports, concurrent access to different
  addresses, randomised traffic over a partitioned address space at three clock
  ratios, and a full sweep written from one port and read from the other.
- `tb/tb_ram_dp.sv` — portable smoke test at a 10 ns / 17 ns clock ratio.

Full documentation: [`docs/index.rst`](docs/index.rst).
