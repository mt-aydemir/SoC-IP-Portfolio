#============================================================================
# ip/crypto - random bits, hashing and block ciphers
#
# A pseudo-random source for test patterns and scrambling, a SHA-256 core
# with the message padding done in hardware, and an AES-128 core that
# encrypts and decrypts with its key schedule computed on the fly. The
# hash and the cipher are checked against hashlib and the FIPS-197 vectors.
#============================================================================
add_ip_category(crypto
  lfsr_rng
  sha256
  aes128
)
