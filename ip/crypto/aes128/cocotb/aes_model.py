"""AES-128 reference model, written from FIPS-197 and sharing nothing with the RTL.

The S-box is computed here from its definition - the GF(2**8) inverse and
the affine map - rather than copied from the generated ROM, so a ROM that
drifted from FIPS-197 fails the regression. Blocks and keys are 128-bit
integers with the first byte in the top bits, the way FIPS-197 prints them.
"""
from __future__ import annotations


def _xtime(a: int) -> int:
    a <<= 1
    return a ^ 0x11B if a & 0x100 else a


def _mul(a: int, b: int) -> int:
    r = 0
    while b:
        if b & 1:
            r ^= a
        a = _xtime(a)
        b >>= 1
    return r


def _build_sbox() -> list[int]:
    # Generator 3 walks the multiplicative group, giving every inverse.
    inverse = [0] * 256
    p = 1
    log = {}
    for i in range(255):
        log[p] = i
        p = _mul(p, 3)
    exp = {i: v for v, i in log.items()}
    for x in range(1, 256):
        inverse[x] = exp[(255 - log[x]) % 255]
    table = []
    for x in range(256):
        b = inverse[x]
        rot = lambda v, n: ((v << n) | (v >> (8 - n))) & 0xFF
        table.append(b ^ rot(b, 1) ^ rot(b, 2) ^ rot(b, 3) ^ rot(b, 4) ^ 0x63)
    return table


SBOX = _build_sbox()
INV_SBOX = [SBOX.index(y) for y in range(256)]
RCON = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1B, 0x36]


def _bytes(x: int) -> list[int]:
    return list(x.to_bytes(16, "big"))


def _int(b: list[int]) -> int:
    return int.from_bytes(bytes(b), "big")


def expand_key(key: int) -> list[int]:
    """The eleven round keys, as 128-bit integers."""
    w = [list(key.to_bytes(16, "big")[4 * i:4 * i + 4]) for i in range(4)]
    for i in range(4, 44):
        t = list(w[i - 1])
        if i % 4 == 0:
            t = [SBOX[v] for v in t[1:] + t[:1]]
            t[0] ^= RCON[i // 4 - 1]
        w.append([a ^ b for a, b in zip(w[i - 4], t)])
    return [_int(w[4 * r] + w[4 * r + 1] + w[4 * r + 2] + w[4 * r + 3]) for r in range(11)]


# The state as a flat list of 16 bytes, s[r + 4c], exactly the input order.

def _shift_rows(s: list[int], sign: int) -> list[int]:
    return [s[r + 4 * ((c + sign * r) % 4)] for c in range(4) for r in range(4)]


def _mix(s: list[int], m: tuple[int, int, int, int]) -> list[int]:
    out = []
    for c in range(4):
        col = s[4 * c:4 * c + 4]
        for r in range(4):
            out.append(_mul(col[0], m[(0 - r) % 4]) ^ _mul(col[1], m[(1 - r) % 4])
                       ^ _mul(col[2], m[(2 - r) % 4]) ^ _mul(col[3], m[(3 - r) % 4]))
    return out


def _add(s: list[int], k: int) -> list[int]:
    return [a ^ b for a, b in zip(s, _bytes(k))]


def encrypt(key: int, block: int) -> int:
    rk = expand_key(key)
    s = _add(_bytes(block), rk[0])
    for r in range(1, 11):
        s = _shift_rows([SBOX[v] for v in s], +1)
        if r != 10:
            s = _mix(s, (2, 3, 1, 1))
        s = _add(s, rk[r])
    return _int(s)


def decrypt(key: int, block: int) -> int:
    rk = expand_key(key)
    s = _add(_bytes(block), rk[10])
    for r in range(9, -1, -1):
        s = [INV_SBOX[v] for v in _shift_rows(s, -1)]
        s = _add(s, rk[r])
        if r != 0:
            s = _mix(s, (0xE, 0xB, 0xD, 0x9))
    return _int(s)


# FIPS-197 appendices B and C.1, and NIST AESAVS known-answer examples:
# (key, plaintext, ciphertext).
VECTORS = [
    (0x2B7E151628AED2A6ABF7158809CF4F3C, 0x3243F6A8885A308D313198A2E0370734,
     0x3925841D02DC09FBDC118597196A0B32),
    (0x000102030405060708090A0B0C0D0E0F, 0x00112233445566778899AABBCCDDEEFF,
     0x69C4E0D86A7B0430D8CDB78070B4C55A),
    (0x00000000000000000000000000000000, 0xF34481EC3CC627BACD5DC3FB08F273E6,
     0x0336763E966D92595A567CC9CE537F5E),
    (0x80000000000000000000000000000000, 0x00000000000000000000000000000000,
     0x0EDD33D3C621E546455BD8BA1418BEC8),
]

# FIPS-197 appendix A.1: the last round key of the appendix B key.
LAST_ROUND_KEY_B = 0xD014F9A8C9EE2589E13F0CC8B6630CA6
