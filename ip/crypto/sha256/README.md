# sha256

SHA-256 (FIPS 180-4) over a 32-bit word stream, one round per cycle, with
the message padding done in hardware.

Send a message of any byte length as big-endian words; mark the last one
with `s_last` and say how many of its bytes are used. The block appends the
`0x80` byte, the zeros and the 64-bit bit length itself - spilling into an
extra block when the message ends 56 or more bytes into one - and returns
the 256-bit digest.

Rounds 0 to 15 use the message words directly, so they run while the words
arrive; rounds 16 to 63 take their words from a 16-word schedule window, and
one more cycle adds the result into the hash value. A block takes 65 cycles
when its words arrive back to back.

| | |
|---|---|
| **Category** | `crypto` |
| **Top module** | `sha256` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Throughput** | 512 bits per 65 cycles |
| **Latency** | 65 cycles per block; the digest follows the last block's final addition |
| **Verified at** | the only configuration (no parameters) |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `s_valid` / `s_ready` | in / out | 1 | Message word handshake |
| `s_data` | in | 32 | Message word, first byte in bits 31:24 |
| `s_last` | in | 1 | Last word of the message |
| `s_nbytes` | in | 3 | Bytes used in the last word, 0 to 4 from the top; above 4 counts as 4; ignored on other words |
| `m_valid` / `m_ready` | out / in | 1 | Digest handshake |
| `m_digest` | out | 256 | `H0` in bits 255:224 down to `H7`; the usual big-endian digest |

The empty message is a lone `s_last` word with `s_nbytes = 0`. A message
whose length is a multiple of four may end either with a full last word or
with an extra `s_last` word carrying no bytes. The next message is accepted
while a digest waits; it stalls before its final addition until the waiting
digest has been taken.

## Quick start

```bash
ctest --test-dir build -R 'sha256'
```

Documentation: [`docs/index.rst`](docs/index.rst).
