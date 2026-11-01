"""Access to the elaboration parameters a test was built with.

``run_cocotb.py`` exports every ``--param NAME=VALUE`` as the environment
variable ``SOCIP_PARAM_<NAME>``. Reading parameters this way is portable
across simulator back ends, unlike reading them through a simulator handle,
which Verilator only exposes for public parameters and which VHDL back ends
do not expose at all.
"""
from __future__ import annotations

import os
from typing import Any, TypeVar

T = TypeVar("T")


def get_param(name: str, default: T) -> T:
    """Return elaboration parameter *name*, or *default* if it was not set.

    The returned value is coerced to the type of *default*, so a test that
    passes ``default=8`` always receives an ``int``.
    """
    raw = os.environ.get(f"SOCIP_PARAM_{name.upper()}")
    if raw is None:
        return default
    if isinstance(default, bool):
        return raw.strip().lower() in ("1", "true", "yes")  # type: ignore[return-value]
    if isinstance(default, int):
        return int(raw, 0)  # type: ignore[return-value]
    if isinstance(default, float):
        return float(raw)  # type: ignore[return-value]
    return raw  # type: ignore[return-value]


def all_params() -> dict[str, str]:
    """Every parameter override visible to this run, for logging."""
    prefix = "SOCIP_PARAM_"
    return {k[len(prefix):]: v for k, v in os.environ.items() if k.startswith(prefix)}


def describe(dut: Any = None) -> str:
    """One-line rendering of the build configuration, for the test log."""
    params = all_params()
    if not params:
        return "parameters: RTL defaults"
    return "parameters: " + ", ".join(f"{k}={v}" for k, v in sorted(params.items()))
