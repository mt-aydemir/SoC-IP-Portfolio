.. _ip-aes128:

======
aes128
======

AES-128 block cipher (FIPS-197), encryption and decryption, one round per
cycle, with the key schedule computed on the fly in both directions.

Functional description
======================

Byte order
----------

As in FIPS-197: the first byte of a block or key is bits 127:120, and the
state is filled column by column, so byte (row ``r``, column ``c``) is bits
``127-8*(r+4c)`` down to ``120-8*(r+4c)``. The standard's example vectors,
read as 128-bit hexadecimal numbers, apply unchanged.

Keys
----

``key_valid`` / ``key_ready`` loads a cipher key. Decryption starts from the
last round key, so a key load runs the key schedule forward once, ten
cycles, and keeps both the first and the last round key; with
``DECRYPT = 0`` the load only stores the key. No block is accepted before
the first key, nor while a key loads, and a key load takes precedence over a
block offered on the same cycle. A new key may be loaded between any two
blocks.

Blocks
------

``s_valid`` / ``s_ready`` accepts a block, and ``s_decrypt``, sampled with
it, selects decryption. Encryption is the cipher of FIPS-197 section 5.1;
decryption the inverse cipher of section 5.3:

.. code-block:: text

   encrypt: s = in ^ K0
            rounds 1..10: SubBytes, ShiftRows, MixColumns (not in 10), ^ Kr
   decrypt: s = in ^ K10
            rounds 1..10: InvShiftRows, InvSubBytes, ^ K(10-r),
                          InvMixColumns (not in 10)

Each round key is derived from the previous one in the same cycle as the
round that uses it, so no key memory is needed:

.. code-block:: text

   forward:  n0 = w0 ^ SubWord(RotWord(w3)) ^ Rcon,  n1 = w1 ^ n0,
             n2 = w2 ^ n1,  n3 = w3 ^ n2
   backward: w3 = n3 ^ n2,  w2 = n2 ^ n1,  w1 = n1 ^ n0,
             w0 = n0 ^ SubWord(RotWord(w3)) ^ Rcon

The two directions share the key schedule's four S-boxes: their inputs
differ only in which ``w3`` is rotated.

Timing
------

The accepting edge applies the initial AddRoundKey, rounds 1 to 10 take one
edge each, and ``m_valid`` rises after the tenth. The result register is
also the round state, so the next block is accepted when the result is taken
- on the same edge at the earliest: eleven cycles per block.

S-boxes
-------

``rtl/aes_sbox.sv`` and ``rtl/aes_inv_sbox.sv`` are 256-entry ROMs generated
by ``scripts/gen_sbox.py`` from the definition in FIPS-197 section 5.1.1:
the inverse in GF(2**8), then the affine transformation. Twenty forward and
sixteen inverse instances make up most of the area. The cocotb model builds
its own S-box from the field arithmetic, and the SystemVerilog testbench
builds a third by searching for inverses, so a ROM that drifted fails both
suites; ``gen_sbox.py --check`` reports one directly.

Block diagram
=============

.. code-block:: text

   key --> forward schedule, 10 steps --> K0, K10

   s_data ^ (K0 or K10) --> state
                              |
              +---------------+---------------+
              v                               v
   SubBytes, ShiftRows,            InvShiftRows, InvSubBytes,
   MixColumns, ^ rk_next           ^ rk_prev, InvMixColumns
              |                               |
              +-------> next state <----------+

   rk --> one schedule step, 4 shared S-boxes --> rk_next, rk_prev

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 18 14 10 20 38

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``DECRYPT``
     - ``int unsigned``
     - 1
     - 0, 1
     - 1 builds the inverse cipher, its sixteen inverse S-boxes and the
       backward key schedule; 0 leaves them out and ignores ``s_decrypt``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 22 8 18 52

   * - Signal
     - Dir
     - Width
     - Description
   * - ``clk``, ``rst_n``
     - in
     - 1
     - Clock and active-low asynchronous reset.
   * - ``key_valid`` / ``key_ready``
     - in / out
     - 1
     - Key load handshake; ``key_ready`` is high whenever no block or key
       load is in progress.
   * - ``key``
     - in
     - 128
     - Cipher key.
   * - ``s_valid`` / ``s_ready``
     - in / out
     - 1
     - Block handshake.
   * - ``s_data``
     - in
     - 128
     - Plaintext or ciphertext.
   * - ``s_decrypt``
     - in
     - 1
     - Decrypt this block.
   * - ``m_valid`` / ``m_ready``
     - out / in
     - 1
     - Result handshake.
   * - ``m_data``
     - out
     - 128
     - Result.

Integration notes
-----------------

* This is the bare block cipher. A mode - CTR, CBC, GCM - is built around
  it: CTR needs only encryption, so ``DECRYPT = 0`` saves the inverse
  datapath.
* The design makes no claim of side-channel resistance: the S-boxes are
  plain ROMs and the power drawn depends on the data. Protect it at the
  system level if that matters.
* ``s_ready`` depends combinationally on ``key_valid``, because a key load
  wins over a block on the same cycle.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_aes128.py``
     - Every result against ``aes_model.py``, written from FIPS-197 with its
       own S-box. The FIPS-197 appendix B and C.1 vectors and two NIST
       AESAVS known answers in both directions; the model's key schedule
       against appendix A.1; the key-load and block cycle counts; a key
       offered with a block; key changes between blocks; ``s_decrypt``
       with and without ``DECRYPT``; a reset mid-block; and random keys,
       blocks and directions under gaps and back-pressure, with every
       ciphertext decrypted back. Run at ``DECRYPT`` = 1 and 0.
   * - ``tb/tb_aes128.sv``
     - The appendix B and C.1 vectors, then 1500 random blocks in both
       directions under changing keys, against a behavioural reference
       with an S-box built by searching for inverses.

.. code-block:: bash

   ctest --test-dir build -R 'aes128'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration. The longest
register-to-register logic is a decryption round: the backward key step - two
XORs and an S-box - into AddRoundKey, then InvMixColumns, into the state
register. In the registered flow the worst reported path is the
combinational ``key_valid`` to ``s_ready`` path, under the default input and
output delays.
