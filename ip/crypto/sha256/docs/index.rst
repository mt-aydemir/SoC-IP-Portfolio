.. _ip-sha256:

======
sha256
======

SHA-256 (FIPS 180-4) over a 32-bit word stream, one round per cycle, with the
message padding done in hardware.

Functional description
======================

Input
-----

The message arrives as big-endian 32-bit words: its first byte is
``s_data[31:24]``. Every word but the last carries four bytes; the last,
marked by ``s_last``, carries ``s_nbytes`` of them, from the top. Bytes
below ``s_nbytes`` in the last word are ignored, ``s_nbytes`` above 4 counts
as 4, and ``s_nbytes`` on other words is ignored. Any byte length is
accepted: the empty message is a lone ``s_last`` word with ``s_nbytes = 0``,
and a message whose length is a multiple of four may end with a full last
word or with an extra, empty ``s_last`` word.

Padding
-------

The block appends what FIPS 180-4 section 5.1.1 prescribes: the byte
``0x80``, zeros up to 56 bytes into a block, and the message length in bits
as a 64-bit big-endian number in the block's last two words. The padding
words are generated one per cycle, in the slots where message words would
otherwise arrive:

* the ``0x80`` byte goes into the last word itself when that word has room,
  or into the next slot when it is full;
* slot 14 carries the length's high word once the ``0x80`` byte is out, and
  slot 15 the low word, ending the message;
* when the ``0x80`` byte lands in slot 14 or 15 - the message ended 56 or
  more bytes into the block - those slots are zero and the length goes into
  one more block of padding.

The length counter is 64 bits wide, so messages up to ``2**61 - 1`` bytes
are hashed correctly.

Rounds
------

.. code-block:: text

   T1 = h + S1(e) + Ch(e,f,g) + K[t] + W[t]
   T2 = S0(a) + Maj(a,b,c)
   h,g,f,e,d,c,b,a = g, f, e, d + T1, c, b, a, T1 + T2

Round ``t`` < 16 uses message word ``t`` as it arrives, so loading and
hashing overlap and those rounds go at the rate of the input. Rounds 16 to
63 take their word from the schedule

.. code-block:: text

   W[t] = s1(W[t-2]) + W[t-7] + s0(W[t-15]) + W[t-16]

kept in a 16-word shift register. One more cycle adds the working variables
into the hash value ``H``; the sum is also the next block's starting state,
so no cycle is spent reloading it. A block takes 65 cycles when its words
arrive back to back.

Output
------

``m_digest`` is ``H0`` in bits 255:224 down to ``H7`` in bits 31:0: the
digest as it is usually printed, first byte on top. It is held from
``m_valid`` until ``m_ready``. The next message is accepted while a digest
waits; only its final addition stalls until the waiting digest is taken.

Block diagram
=============

.. code-block:: text

   s_data --> [last-word mask, 0x80] --+
                                       +--> W[t] --> round: T1, T2 --> a..h
   [padding: 0x80, zeros, length] -----+      ^                         |
                                              |                         v
   W window (16 words) --> s0, s1, adds ------+          H + a..h --> m_digest

Parameter table
===============

The block has no parameters.

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
   * - ``s_valid`` / ``s_ready``
     - in / out
     - 1
     - Message word handshake; ``s_ready`` is low during rounds 16 to 63,
       the final addition and the padding.
   * - ``s_data``
     - in
     - 32
     - Message word, first byte in bits 31:24.
   * - ``s_last``
     - in
     - 1
     - Last word of the message.
   * - ``s_nbytes``
     - in
     - 3
     - Bytes used in the last word, 0 to 4.
   * - ``m_valid`` / ``m_ready``
     - out / in
     - 1
     - Digest handshake.
   * - ``m_digest``
     - out
     - 256
     - The digest, ``H0`` on top.

Integration notes
-----------------

* For HMAC, hash the key block and the message as one message; the block
  keeps no state between messages beyond the waiting digest.
* A source that cannot supply a word per cycle only slows rounds 0 to 15;
  the other 49 cycles of a block do not depend on it.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_sha256.py``
     - Every digest against Python's ``hashlib``. The FIPS 180-4 example
       messages with their published digests; every length from 0 to 140
       bytes, covering each padding case; the exact cycle count of 1-, 2-
       and 7-block messages and of the 56-byte spill; a digest left waiting
       while three more messages stream in; junk in ignored bytes and
       ``s_nbytes`` above 4; a reset mid-message; and random messages and
       endings under gaps and back-pressure.
   * - ``tb/tb_sha256.sv``
     - "abc", the 448-bit message and one million "a" against their
       published digests, then 300 random messages against a textbook
       reference that pads the whole message up front and expands all 64
       schedule words per block.

.. code-block:: bash

   ctest --test-dir build -R 'sha256'

Timing
======

Timed by OpenSTA at the period in the ``add_ip()`` registration. The
longest register-to-register logic is one round: the schedule word (three
additions), the five-operand sum ``T1`` and the addition ``T1 + T2`` into
``a``. Rounds 0 to 15 start that sum from ``s_data``, so in the registered
flow the worst reported path begins at the input port.
