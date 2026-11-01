# template_ip

One-sentence summary of the block.

A single registered stage on a ready/valid stream: a word presented at the
input appears at the output one clock later, and the input stalls whenever the
output is occupied and the sink is not accepting.

| | |
|---|---|
| **Category** | `<category>` |
| **Top module** | `template_ip` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Latency** | 1 cycle |
| **Throughput** | 1 transfer/cycle when the sink does not stall |
| **Verified at** | 10.0 ns clock period |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Rising-edge clock |
| `rst_n` | in | 1 | Active-low reset |
| `s_valid` | in | 1 | Input payload valid |
| `s_ready` | out | 1 | Block accepts a word this cycle |
| `s_data` | in | `DATA_WIDTH` | Input payload |
| `m_valid` | out | 1 | Output payload valid |
| `m_ready` | in | 1 | Sink accepts a word this cycle |
| `m_data` | out | `DATA_WIDTH` | Output payload |

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DATA_WIDTH` | `int unsigned` | 8 | >= 1 | Payload width on both interfaces |

## Quick start

```systemverilog
template_ip #(
  .DATA_WIDTH (32)
) u_stage (
  .clk     (clk),
  .rst_n   (rst_n),
  .s_valid (up_valid),
  .s_ready (up_ready),
  .s_data  (up_data),
  .m_valid (dn_valid),
  .m_ready (dn_ready),
  .m_data  (dn_data)
);
```

## Verification

```bash
ctest --test-dir build -R 'template_ip'
```

- `cocotb/test_template_ip.py` — directed, randomised and regression suites
  against an in-order scoreboard.
- `tb/tb_template_ip.sv` — portable self-checking smoke test, no Python needed.

## Files

```
rtl/template_ip.sv          synthesisable RTL
tb/tb_template_ip.sv        SystemVerilog testbench
cocotb/test_template_ip.py  cocotb regression
docs/index.rst              full documentation
scripts/template_ip.sdc     timing constraints
```

Full documentation: [`docs/index.rst`](docs/index.rst).
