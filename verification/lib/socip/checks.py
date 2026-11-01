"""Assertion and bit-manipulation helpers used across all testbenches."""
from __future__ import annotations

from typing import Any


class CheckError(AssertionError):
    """Raised when a testbench check fails."""


def to_int(value: Any) -> int:
    """Coerce a cocotb handle / BinaryValue / int to a plain Python int.

    Raises CheckError if the value contains X or Z, which is almost always a
    real design bug rather than something a test should tolerate.
    """
    if isinstance(value, int):
        return value
    try:
        return int(value)
    except (ValueError, TypeError) as exc:
        raise CheckError(f"value is not resolvable to an integer: {value!r}") from exc


def assert_eq(actual: Any, expected: Any, message: str = "") -> None:
    """Compare two values, reporting both hex and decimal on failure."""
    a, e = to_int(actual), to_int(expected)
    if a != e:
        prefix = f"{message}: " if message else ""
        raise CheckError(
            f"{prefix}expected 0x{e:X} ({e}), got 0x{a:X} ({a})")


def assert_within(actual: Any, expected: Any, tolerance: int,
                  message: str = "") -> None:
    """Compare with an absolute tolerance, for quantised DSP results."""
    a, e = to_int(actual), to_int(expected)
    if abs(a - e) > tolerance:
        prefix = f"{message}: " if message else ""
        raise CheckError(
            f"{prefix}expected {e} +/- {tolerance}, got {a} (error {a - e})")


def bits(value: int, width: int) -> int:
    """Truncate *value* to *width* bits, two's complement wrap-around."""
    return value & ((1 << width) - 1)


def to_signed(value: int, width: int) -> int:
    """Reinterpret the low *width* bits of *value* as a signed integer."""
    value = bits(value, width)
    sign = 1 << (width - 1)
    return value - (1 << width) if value & sign else value


def sign_extend(value: int, from_width: int, to_width: int) -> int:
    """Sign-extend *value* from *from_width* to *to_width* bits."""
    return bits(to_signed(value, from_width), to_width)
