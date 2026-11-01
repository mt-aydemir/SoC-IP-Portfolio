.. _ip-alu:

===
alu
===

Combinational arithmetic and logic unit with condition flags.

Functional description
======================

A datapath ALU: one operation per cycle selected by a four-bit opcode, with
the four classical condition flags — zero, negative, carry and overflow —
produced alongside the result.

The block is combinational. Where it sits in a pipeline, the stage register
belongs to the pipeline, not to the ALU, for the same reason the adder carries
no register: only the caller knows where the stage boundary is.

Structure
---------

The adder and the shifter are instantiated rather than rewritten, so the
portfolio contains one implementation of two's complement addition with
overflow detection and one barrel shifter.

* **One adder serves five opcodes.** ``ADD`` uses it directly. ``SUB``,
  ``SLT`` and ``SLTU`` invert the second operand, which is the same
  ``a + ~b + carry`` identity ``subtractor`` uses and the way the hardware does
  it. The adder is instantiated signed so that it always reports signed
  overflow on V; the unsigned carry is taken from its carry out, which is
  interpretation-independent.
* **One shifter serves five opcodes.** The opcode is decoded to the shifter's
  own three-bit operation code, and ``b``'s low ``$clog2(WIDTH)`` bits are
  the amount.
* **The comparisons reuse the subtraction.** Signed less-than is the sign of
  the difference corrected for overflow, ``N XOR V``; unsigned less-than is
  "a borrow occurred", the inverted carry.

Opcodes
-------

.. list-table::
   :header-rows: 1
   :widths: 10 12 40 38

   * - Code
     - Name
     - Result
     - Flags written
   * - ``0x0``
     - ``ADD``
     - ``a + b + carry_in``
     - Z N C V
   * - ``0x1``
     - ``SUB``
     - ``a - b - !carry_in``
     - Z N C V
   * - ``0x2``
     - ``AND``
     - ``a & b``
     - Z N; C = V = 0
   * - ``0x3``
     - ``OR``
     - ``a | b``
     - Z N; C = V = 0
   * - ``0x4``
     - ``XOR``
     - ``a ^ b``
     - Z N; C = V = 0
   * - ``0x5``
     - ``NOT``
     - ``~a``
     - Z N; C = V = 0
   * - ``0x6``
     - ``SLL``
     - ``a << b``
     - Z N; C = V = 0
   * - ``0x7``
     - ``SRL``
     - ``a >> b``, logical
     - Z N; C = V = 0
   * - ``0x8``
     - ``SRA``
     - ``a >>> b``, arithmetic
     - Z N; C = V = 0
   * - ``0x9``
     - ``ROL``
     - ``a`` rotated left by ``b``
     - Z N; C = V = 0
   * - ``0xA``
     - ``ROR``
     - ``a`` rotated right by ``b``
     - Z N; C = V = 0
   * - ``0xB``
     - ``SLT``
     - 1 if ``a < b`` signed, else 0
     - Z N; C = V = 0
   * - ``0xC``
     - ``SLTU``
     - 1 if ``a < b`` unsigned, else 0
     - Z N; C = V = 0
   * - ``0xD``
     - ``PASS``
     - ``a``
     - Z N; C = V = 0
   * - ``0xE``
     - ``PASSB``
     - ``b``
     - Z N; C = V = 0
   * - ``0xF``
     - —
     - ``0``
     - Z = 1; N = C = V = 0

The flags
---------

Flag semantics are the part of an ALU most often got wrong, because they
differ between architectures and the difference is invisible until a
conditional branch behaves oddly. The conventions here are:

Z — zero
   The result is all zeros.

N — negative
   The result's most significant bit, which is the sign under a two's
   complement interpretation.

C — carry
   For ``ADD``, the carry out of the top bit. For ``SUB``, the **inverted
   borrow** — the ARM and x86 convention rather than the 6502 one — so "carry
   set" means "no borrow". ``carry_in`` into ``SUB`` follows the same
   convention.

V — overflow
   The signed result was not representable.

C and V are only meaningful for the arithmetic operations. Every other opcode
clears both rather than leaving stale values, so a consumer never has to
remember which opcode last wrote them.

Multi-word arithmetic
---------------------

``ADD`` and ``SUB`` both take a carry so that arithmetic wider than ``WIDTH``
can be built from successive operations:

.. code-block:: text

   low  = ADD(a_lo, b_lo, carry_in = 0)    ; C -> c
   high = ADD(a_hi, b_hi, carry_in = c)

   low  = SUB(a_lo, b_lo, carry_in = 1)    ; C -> c   (1 means "no borrow")
   high = SUB(a_hi, b_hi, carry_in = c)

The comparisons do not chain. ``SLT`` and ``SLTU`` always compute a plain
``a - b`` and ignore ``carry_in``.

Block diagram
=============

.. code-block:: text

                 +------------------------------------------------------+
   a  ==========>|==+===========================+=====================> |
     [W]         |  |                           |                       |
   b  ==========>|  |   +-------+               |                       |
     [W]         |  |   | ~b if |   +-------+   |   +----------------+  |
                 |  +-->| SUB/  |-->| adder |   +-->| barrel_shifter |  |
   carry_in ---->|  |   | SLT(U)|   |SIGNED |       | amount = b[lo] |  |
                 |  |   +-------+   +-------+       +----------------+  |
                 |  |                | sum | C | V          |           |
                 |  |                v     v   v            v           |
                 |  |   +-------+   +-----------+   +--------------+    |
                 |  +-->| logic |   | SLT = N^V |   | shift result |    |
                 |      | & | ^ |   | SLTU = ~C |   +--------------+    |
                 |      +-------+   +-----------+          |            |
                 |          |             |                 |            |
                 |          v             v                 v            |
   opcode ------>|   +--------------------------------------------+     |
     [4]         |   |              result select                 |====>|==> result
                 |   +--------------------------------------------+     |
                 |        Z = (result == 0), N = result[W-1]            |---> Z, N
                 |        C, V = adder flags for ADD/SUB, else 0        |---> C, V
                 +------------------------------------------------------+

Parameter table
===============

.. list-table::
   :header-rows: 1
   :widths: 18 14 10 16 42

   * - Parameter
     - Type
     - Default
     - Legal range
     - Effect
   * - ``WIDTH``
     - ``int unsigned``
     - 32
     - >= 2
     - Operand and result width. The shift amount is the low
       ``$clog2(WIDTH)`` bits of ``b``.

Illegal parameter values are rejected at elaboration with ``$fatal``.

Interface description
=====================

.. list-table::
   :header-rows: 1
   :widths: 18 10 14 58

   * - Signal
     - Dir
     - Width
     - Description
   * - ``a``
     - in
     - ``WIDTH``
     - First operand, and the value shifted by the shift opcodes.
   * - ``b``
     - in
     - ``WIDTH``
     - Second operand. Its low ``$clog2(WIDTH)`` bits are the shift amount.
   * - ``opcode``
     - in
     - 4
     - Operation select; see the opcode table.
   * - ``carry_in``
     - in
     - 1
     - Carry into ``ADD``; "no borrow" into ``SUB``. Ignored by every other
       opcode.
   * - ``result``
     - out
     - ``WIDTH``
     - Result.
   * - ``flag_zero``
     - out
     - 1
     - Z.
   * - ``flag_negative``
     - out
     - 1
     - N.
   * - ``flag_carry``
     - out
     - 1
     - C. Zero for every non-arithmetic opcode.
   * - ``flag_overflow``
     - out
     - 1
     - V. Zero for every non-arithmetic opcode.

Usage examples
==============

A single-cycle execute stage
----------------------------

.. code-block:: systemverilog

   alu #(
     .WIDTH (32)
   ) u_alu (
     .a             (rs1_value),
     .b             (use_immediate ? immediate : rs2_value),
     .opcode        (alu_op),
     .carry_in      (alu_op == 4'h1),   // plain SUB: carry in = no borrow
     .result        (alu_result),
     .flag_zero     (z),
     .flag_negative (n),
     .flag_carry    (c),
     .flag_overflow (v)
   );

   // Conditional branches on the flags, ARM-style.
   assign branch_eq  =  z;
   assign branch_lt  =  n ^ v;          // signed less than
   assign branch_ltu = ~c;              // unsigned less than (borrow)

Integration notes
-----------------

* For a plain subtraction drive ``carry_in = 1``. Driving 0 subtracts one
  more, which is correct only when it is the borrow from a lower word.
* The critical path is the adder's carry chain followed by the result
  multiplexer, or the shifter's mux tree followed by the same multiplexer,
  whichever is longer at the chosen width. The flags add a zero-detect on top
  of the result, so Z is the latest-arriving output.
* The ``0xF`` encoding returns zero rather than being left undefined; that
  keeps the block free of inferred latches.

Verification
============

.. list-table::
   :header-rows: 1
   :widths: 30 70

   * - Suite
     - Contents
   * - ``cocotb/test_alu.py``
     - Every opcode, including the undefined one, on simple operands and both
       carry values; C and V cleared by every non-arithmetic opcode
       immediately after an overflowing addition; the carry-as-no-borrow
       convention; double-width addition and subtraction chained through
       ``carry_in``; the signed and unsigned comparisons at the sign boundary
       where they disagree; 4000 corner-biased randomised operations; an
       exhaustive sweep at narrow widths; and a statelessness check.
   * - ``tb/tb_alu.sv``
     - Portable self-checking testbench sweeping every opcode and carry value
       across the operand space at ``WIDTH=8``, plus randomised vectors.
   * - ``formal/alu_formal.sv``
     - Exhaustive equivalence proof at ``WIDTH=16``: every opcode, the result
       and all four flags against integer-arithmetic references.

.. code-block:: bash

   ctest --test-dir build -R 'alu'

Timing
======

The block is registered with ``NO_STA``: it is combinational, so there is no
setup or hold check to make on it in isolation. Its timing is covered by the
analysis of the pipeline that instantiates it.
