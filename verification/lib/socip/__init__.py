"""socip - shared cocotb verification library for the SoC IP portfolio.

Every IP testbench imports from here rather than re-implementing clock and
reset generation, scoreboards or bus transactors. Keeping this logic in one
place is what makes 50+ testbenches consistent and maintainable.
"""
from socip.clocking import (
    ClockDomain,
    start_clock,
    reset_active_low,
    reset_active_high,
    settle,
    between_edges,
)
from socip.scoreboard import Scoreboard, ScoreboardError
from socip.checks import assert_eq, assert_within, bits, sign_extend, to_signed
from socip.stimulus import RandomStream, constrained_ints, weighted_choice
from socip.params import get_param, all_params, describe
from socip.stream import StreamSink, StreamSource, expect_stream, sample, sampled

__all__ = [
    "StreamSource",
    "StreamSink",
    "expect_stream",
    "sample",
    "sampled",
    "get_param",
    "all_params",
    "describe",
    "ClockDomain",
    "start_clock",
    "reset_active_low",
    "reset_active_high",
    "settle",
    "between_edges",
    "Scoreboard",
    "ScoreboardError",
    "assert_eq",
    "assert_within",
    "bits",
    "sign_extend",
    "to_signed",
    "RandomStream",
    "constrained_ints",
    "weighted_choice",
]

__version__ = "0.1.0"
