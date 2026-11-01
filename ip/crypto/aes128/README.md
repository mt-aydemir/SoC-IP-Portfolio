# aes128

AES-128 block cipher (FIPS-197), encryption and decryption, one round per
cycle, with the key schedule computed on the fly in both directions.

Load a key once; then each block is encrypted or decrypted, chosen per block
with `s_decrypt`, in eleven cycles. Every round key is derived from the
previous one in the same cycle as the round that uses it - forward from the
cipher key when encrypting, backward from the last round key when
decrypting - so no key memory is needed. A key load runs the schedule
forward once, ten cycles, to find that last round key.

The S-box ROMs are generated from their definition by
`scripts/gen_sbox.py`; the test model computes its own S-box, so a table
that drifted fails the regression.

| | |
|---|---|
| **Category** | `crypto` |
| **Top module** | `aes128` |
| **Clock domains** | 1 (`clk`) |
| **Reset** | `rst_n`, active low, async assert / sync release |
| **Throughput** | one 128-bit block per 11 cycles |
| **Latency** | 11 cycles; a key load takes 11 (1 with `DECRYPT=0`) |
| **Verified at** | `DECRYPT=1` and `DECRYPT=0` |
| **Licence** | Apache-2.0 |

## Interface

| Signal | Dir | Width | Description |
|---|---|---|---|
| `key_valid` / `key_ready` | in / out | 1 | Key load handshake; `key_ready` is high between blocks |
| `key` | in | 128 | Cipher key, first byte in bits 127:120 |
| `s_valid` / `s_ready` | in / out | 1 | Block handshake; no block is accepted before the first key |
| `s_data` | in | 128 | Plaintext or ciphertext, first byte in bits 127:120 |
| `s_decrypt` | in | 1 | Decrypt this block; ignored with `DECRYPT=0` |
| `m_valid` / `m_ready` | out / in | 1 | Result handshake |
| `m_data` | out | 128 | Result |

Bytes are in FIPS-197 order, so the standard's example vectors, read as
128-bit hexadecimal numbers, apply unchanged. A key load offered on the same
cycle as a block goes first, and the block then uses the new key.

## Parameters

| Parameter | Type | Default | Range | Effect |
|---|---|---|---|---|
| `DECRYPT` | `int unsigned` | 1 | 0, 1 | 1 builds the inverse cipher and the backward key schedule |

## Quick start

```bash
ctest --test-dir build -R 'aes128'
python ip/crypto/aes128/scripts/gen_sbox.py --check
```

Documentation: [`docs/index.rst`](docs/index.rst).
